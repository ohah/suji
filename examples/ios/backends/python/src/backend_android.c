// Android embedded CPython 백엔드 (suji_python_backend_*) — iOS 의 backend.zig 와
// 동일 로직의 C 포팅. Android 는 zig @cImport(Python.h) 의 translate-c 가 NDK bionic
// 헤더(배열 nullability/__overloadable ioctl)를 못 풀어, 같은 백엔드를 C 로 두고
// NDK clang 으로 컴파일한다(real clang 은 bionic 무사 — translate-c 미경유).
// C 라 PyArg_ParseTuple variadic 도 정상(zig variadic 버그 비해당).
//
// 호스트(examples/android/python/cpp/backends.c, JNI)가 filesDir 추출 경로로
// suji_python_backend_start(home, entry) 호출 → main.py 가 suji.handle 로 등록 →
// suji_python_backend_channels() 로 이름 받아 각 채널을 suji_core_register_handler.
// outbound suji.invoke/send/on 은 정적 링크된 suji_core_* 직접 호출.

#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "suji_core.h" // extern suji_core_invoke/free/emit/on/off

// 핸들러 레지스트리 — 소규모(선형 탐색). iOS StringHashMap 대응.
typedef struct {
    char *name;
    PyObject *fn;
} Handler;
#define SUJI_PY_MAX_HANDLERS 256
static Handler g_handlers[SUJI_PY_MAX_HANDLERS];
static int g_handler_count = 0;
static PyThreadState *g_main_tstate = NULL;
static int g_initialized = 0;

// ---- suji 모듈 (handle/invoke/send/on) ----

static PyObject *py_handle(PyObject *self, PyObject *args) {
    (void)self;
    const char *ch;
    PyObject *fn;
    if (!PyArg_ParseTuple(args, "sO", &ch, &fn)) return NULL;
    if (!PyCallable_Check(fn)) {
        PyErr_SetString(PyExc_TypeError, "suji.handle: handler must be callable");
        return NULL;
    }
    for (int i = 0; i < g_handler_count; i++) {
        if (strcmp(g_handlers[i].name, ch) == 0) {
            Py_DECREF(g_handlers[i].fn);
            Py_INCREF(fn);
            g_handlers[i].fn = fn;
            Py_RETURN_NONE;
        }
    }
    if (g_handler_count < SUJI_PY_MAX_HANDLERS) {
        Py_INCREF(fn);
        g_handlers[g_handler_count].name = strdup(ch);
        g_handlers[g_handler_count].fn = fn;
        g_handler_count++;
    }
    Py_RETURN_NONE;
}

static PyObject *py_invoke(PyObject *self, PyObject *args) {
    (void)self;
    const char *target, *req;
    if (!PyArg_ParseTuple(args, "ss", &target, &req)) return NULL;
    const char *resp = suji_core_invoke(target, req);
    if (resp) {
        PyObject *out = PyUnicode_FromString(resp);
        suji_core_free(resp);
        return out;
    }
    return PyUnicode_FromString("{}");
}

static PyObject *py_send(PyObject *self, PyObject *args) {
    (void)self;
    const char *ch, *data;
    if (!PyArg_ParseTuple(args, "ss", &ch, &data)) return NULL;
    suji_core_emit(ch, data);
    Py_RETURN_NONE;
}

// EventBus 가 emit 한 스레드에서 호출. arg = 등록 시 INCREF 한 PyObject* 콜백.
static void event_trampoline(const char *name, const char *data, void *arg) {
    (void)name;
    PyObject *cb = (PyObject *)arg;
    PyGILState_STATE g = PyGILState_Ensure();
    PyObject *r = PyObject_CallFunction(cb, "s", data);
    if (r) Py_DECREF(r);
    else if (PyErr_Occurred()) PyErr_Print();
    PyGILState_Release(g);
}

static PyObject *py_on(PyObject *self, PyObject *args) {
    (void)self;
    const char *ch;
    PyObject *fn;
    if (!PyArg_ParseTuple(args, "sO", &ch, &fn)) return NULL;
    if (!PyCallable_Check(fn)) {
        PyErr_SetString(PyExc_TypeError, "suji.on: callback must be callable");
        return NULL;
    }
    Py_INCREF(fn); // 리스너 수명 동안 유지(destroy 까지; 단순화로 명시 해제 생략)
    uint64_t id = suji_core_on(ch, event_trampoline, fn);
    return PyLong_FromUnsignedLongLong((unsigned long long)id);
}

static PyMethodDef suji_methods[] = {
    {"handle", py_handle, METH_VARARGS, NULL},
    {"invoke", py_invoke, METH_VARARGS, NULL},
    {"send", py_send, METH_VARARGS, NULL},
    {"on", py_on, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef suji_module = {
    PyModuleDef_HEAD_INIT, "suji", NULL, -1, suji_methods, NULL, NULL, NULL, NULL,
};

static PyObject *init_suji_module(void) { return PyModule_Create(&suji_module); }

// ---- 부팅 / 디스패치 ----

int suji_python_backend_start(const char *home, const char *entry) {
    if (g_initialized) return 0;
    setenv("NO_COLOR", "1", 1);
    setenv("PYTHON_COLORS", "0", 1);

    if (PyImport_AppendInittab("suji", &init_suji_module) != 0) return -1;

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0; // 추출된 stdlib 에 .pyc 쓰기 회피.

    PyStatus st = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(st)) { PyConfig_Clear(&config); return -2; }

    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) return -3;

    FILE *fp = fopen(entry, "rb");
    if (!fp) return -4;
    int rc = PyRun_SimpleFileExFlags(fp, entry, 1, NULL); // closeit=1 → fclose
    if (rc != 0) {
        if (PyErr_Occurred()) PyErr_Print();
        return -5;
    }

    g_main_tstate = PyEval_SaveThread(); // 메인 GIL 해제 → 이후 Ensure 진입
    g_initialized = 1;
    return 0;
}

void suji_python_backend_init(const void *core) { (void)core; }

// 등록된 핸들러 이름 JSON 배열(호스트가 각 채널 suji_core_register_handler).
char *suji_python_backend_channels(void) {
    size_t cap = 4;
    for (int i = 0; i < g_handler_count; i++) cap += strlen(g_handlers[i].name) + 4;
    char *buf = (char *)malloc(cap);
    if (!buf) return strdup("[]");
    char *p = buf;
    *p++ = '[';
    for (int i = 0; i < g_handler_count; i++) {
        if (i) *p++ = ',';
        *p++ = '"';
        size_t n = strlen(g_handlers[i].name);
        memcpy(p, g_handlers[i].name, n);
        p += n;
        *p++ = '"';
    }
    *p++ = ']';
    *p = '\0';
    return buf;
}

static PyObject *find_handler(const char *cmd) {
    for (int i = 0; i < g_handler_count; i++)
        if (strcmp(g_handlers[i].name, cmd) == 0) return g_handlers[i].fn;
    return NULL;
}

// compact json `{"cmd":"<v>",...}` 에서 cmd 추출(iOS field() 동형).
static int extract_cmd(const char *json, char *out, size_t outsz) {
    const char *pat = "\"cmd\":\"";
    const char *i = strstr(json, pat);
    if (!i) return 0;
    i += strlen(pat);
    const char *e = strchr(i, '"');
    if (!e) return 0;
    size_t n = (size_t)(e - i);
    if (n >= outsz) n = outsz - 1;
    memcpy(out, i, n);
    out[n] = '\0';
    return 1;
}

char *suji_python_backend_handle_ipc(const char *req) {
    char cmd[128];
    if (!extract_cmd(req, cmd, sizeof cmd)) return strdup("{\"error\":\"missing cmd\"}");
    if (!g_initialized) return strdup("{\"error\":\"not initialized\"}");

    PyGILState_STATE g = PyGILState_Ensure();
    PyObject *fn = find_handler(cmd);
    if (!fn) {
        PyGILState_Release(g);
        return strdup("{\"error\":\"unknown handler\"}");
    }
    char *result = NULL;
    PyObject *arg = PyUnicode_FromString(req); // 핸들러는 전체 요청을 받는다(iOS 동일)
    if (arg) {
        PyObject *r = PyObject_CallOneArg(fn, arg);
        Py_DECREF(arg);
        if (r) {
            const char *s = PyUnicode_AsUTF8(r);
            if (s) result = strdup(s);
            Py_DECREF(r);
        } else if (PyErr_Occurred()) {
            PyErr_Print();
        }
    }
    PyGILState_Release(g);
    return result ? result : strdup("{\"error\":\"python handler failed\"}");
}

void suji_python_backend_free(char *p) {
    if (p) free(p);
}

void suji_python_backend_destroy(void) {
    if (g_main_tstate) {
        PyEval_RestoreThread(g_main_tstate);
        g_main_tstate = NULL;
        for (int i = 0; i < g_handler_count; i++) {
            Py_DECREF(g_handlers[i].fn);
            free(g_handlers[i].name);
        }
        Py_FinalizeEx();
    } else {
        for (int i = 0; i < g_handler_count; i++) free(g_handlers[i].name);
    }
    g_handler_count = 0;
    g_initialized = 0;
}
