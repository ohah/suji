const net = require("net");
const _ = require("lodash");
const dayjs = require("dayjs");
const { v4: uuidv4 } = require("uuid");
const crypto = require("crypto");

const SOCK_PATH = process.argv[2];
if (!SOCK_PATH) {
  console.error("[Node] Usage: node backend.js <socket_path>");
  process.exit(1);
}

let callCount = 0;
const sharedState = [];

function handleRequest(reqStr) {
  callCount++;
  let req;
  try {
    req = JSON.parse(reqStr);
  } catch {
    req = { cmd: reqStr };
  }

  const cmd = req.cmd || reqStr;

  switch (cmd) {
    case "ping":
      return JSON.stringify({ from: "node", msg: "pong", count: callCount });

    // lodash 사용
    case "async_work": {
      const tasks = _.map(["task1", "task2", "task3"], (t) => `${t}_done`);
      const sorted = _.sortBy(tasks);
      return JSON.stringify({
        from: "node",
        tasks: sorted,
        count: callCount,
      });
    }

    // dayjs 사용
    case "time_format": {
      const now = dayjs();
      return JSON.stringify({
        from: "node",
        iso: now.toISOString(),
        formatted: now.format("YYYY-MM-DD HH:mm:ss"),
        unix: now.unix(),
        count: callCount,
      });
    }

    // uuid 사용
    case "gen_uuid": {
      const ids = _.times(5, () => uuidv4());
      return JSON.stringify({
        from: "node",
        uuids: ids,
        count: callCount,
      });
    }

    // 공유 상태 쓰기
    case "state_write": {
      sharedState.push(`entry_${callCount}`);
      return JSON.stringify({
        from: "node",
        action: "write",
        state_len: sharedState.length,
        count: callCount,
      });
    }

    // 공유 상태 읽기
    case "state_read": {
      return JSON.stringify({
        from: "node",
        action: "read",
        state_len: sharedState.length,
        last: _.last(sharedState) || "",
      });
    }

    // CPU heavy (SHA256)
    case "cpu_heavy": {
      let hash = Buffer.from(req.data || "default");
      for (let i = 0; i < 1000; i++) {
        hash = crypto.createHash("sha256").update(hash).digest();
      }
      return JSON.stringify({
        from: "node",
        hash_len: hash.toString("hex").length,
        count: callCount,
      });
    }

    // lodash 체이닝 + 대량 데이터
    case "lodash_heavy": {
      const size = req.size || 1000;
      const data = _.chain(_.range(size))
        .map((n) => ({ id: n, value: n * 2 }))
        .filter((item) => item.value % 4 === 0)
        .sortBy("value")
        .take(10)
        .value();
      return JSON.stringify({
        from: "node",
        result_len: data.length,
        total_processed: size,
        count: callCount,
      });
    }

    default:
      return JSON.stringify({ from: "node", echo: cmd, count: callCount });
  }
}

// 메시지 구분을 위해 newline 기반 프로토콜
const server = net.createServer((conn) => {
  console.error("[Node] client connected");
  let buffer = "";

  conn.on("data", (data) => {
    buffer += data.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop(); // 마지막 불완전한 줄은 버퍼에 유지

    for (const line of lines) {
      if (line.trim()) {
        const response = handleRequest(line.trim());
        conn.write(response + "\n");
      }
    }
  });

  conn.on("end", () => {
    // 남은 버퍼 처리
    if (buffer.trim()) {
      const response = handleRequest(buffer.trim());
      conn.write(response + "\n");
    }
    console.error(`[Node] client disconnected (total calls: ${callCount})`);
  });
});

server.listen(SOCK_PATH, () => {
  console.error(`[Node] listening on ${SOCK_PATH} (lodash, dayjs, uuid loaded)`);
});

process.on("SIGTERM", () => {
  server.close();
  process.exit(0);
});
