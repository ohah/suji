package suji

import (
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
)

const defaultTSModule = "@suji/api"

type tsHandler struct {
	channel string
	req     reflect.Type
	res     reflect.Type
}

// TSHandlers builds TypeScript SujiHandlers declarations from explicit Go
// request/response types. Pass nil for a void request or response.
type TSHandlers struct {
	handlers []tsHandler
}

func NewTSHandlers() *TSHandlers {
	return &TSHandlers{}
}

func (b *TSHandlers) Handler(channel string, req any, res any) *TSHandlers {
	b.handlers = append(b.handlers, tsHandler{
		channel: channel,
		req:     tsValueType(req),
		res:     tsValueType(res),
	})
	return b
}

func (b *TSHandlers) Export() (string, error) {
	return b.ExportFor(defaultTSModule)
}

func (b *TSHandlers) ExportFor(moduleName string) (string, error) {
	ctx := &tsContext{
		names:   map[reflect.Type]string{},
		emitted: map[reflect.Type]bool{},
	}

	var out strings.Builder
	out.WriteString("// auto-generated - do not edit\n")
	out.WriteString("declare module '")
	out.WriteString(escapeSingleQuoted(moduleName))
	out.WriteString("' {\n  interface SujiHandlers {\n")
	for _, h := range b.handlers {
		req, err := ctx.render(h.req)
		if err != nil {
			return "", err
		}
		res, err := ctx.render(h.res)
		if err != nil {
			return "", err
		}
		out.WriteString("    ")
		out.WriteString(tsPropertyKey(h.channel))
		out.WriteString(": { req: ")
		out.WriteString(req)
		out.WriteString("; res: ")
		out.WriteString(res)
		out.WriteString(" };\n")
	}
	out.WriteString("  }\n}\n")

	if len(ctx.order) > 0 {
		out.WriteByte('\n')
	}
	for i := 0; i < len(ctx.order); i++ {
		typ := ctx.order[i]
		alias, err := ctx.renderStructAlias(typ)
		if err != nil {
			return "", err
		}
		out.WriteString(alias)
		out.WriteByte('\n')
	}

	return out.String(), nil
}

type tsContext struct {
	names   map[reflect.Type]string
	emitted map[reflect.Type]bool
	order   []reflect.Type
}

func tsValueType(v any) reflect.Type {
	if v == nil {
		return nil
	}
	return reflect.TypeOf(v)
}

func (c *tsContext) render(typ reflect.Type) (string, error) {
	if typ == nil {
		return "void", nil
	}
	for typ.Kind() == reflect.Ptr {
		inner, err := c.render(typ.Elem())
		if err != nil {
			return "", err
		}
		return inner + " | null", nil
	}

	switch typ.Kind() {
	case reflect.Bool:
		return "boolean", nil
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr,
		reflect.Float32, reflect.Float64:
		return "number", nil
	case reflect.String:
		return "string", nil
	case reflect.Slice, reflect.Array:
		elem, err := c.render(typ.Elem())
		if err != nil {
			return "", err
		}
		return elem + "[]", nil
	case reflect.Map:
		key := typ.Key()
		if key.Kind() != reflect.String {
			return "", fmt.Errorf("suji TS helper: map key %s must be string", key)
		}
		value, err := c.render(typ.Elem())
		if err != nil {
			return "", err
		}
		return "Record<string, " + value + ">", nil
	case reflect.Struct:
		if name := typ.Name(); name != "" {
			c.register(typ)
			return name, nil
		}
		return c.renderInlineStruct(typ)
	case reflect.Interface:
		return "unknown", nil
	default:
		return "unknown", nil
	}
}

func (c *tsContext) register(typ reflect.Type) {
	if c.names[typ] != "" {
		return
	}
	c.names[typ] = typ.Name()
	c.order = append(c.order, typ)
}

func (c *tsContext) renderStructAlias(typ reflect.Type) (string, error) {
	if c.emitted[typ] {
		return "", nil
	}
	c.emitted[typ] = true

	body, err := c.renderInlineStruct(typ)
	if err != nil {
		return "", err
	}
	return "export type " + typ.Name() + " = " + body + ";\n", nil
}

func (c *tsContext) renderInlineStruct(typ reflect.Type) (string, error) {
	fields := tsStructFields(typ)
	if len(fields) == 0 {
		return "Record<string, never>", nil
	}

	var out strings.Builder
	out.WriteString("{\n")
	for _, field := range fields {
		fieldType, err := c.render(field.typ)
		if err != nil {
			return "", err
		}
		out.WriteString("  ")
		out.WriteString(tsPropertyKey(field.name))
		if field.optional {
			out.WriteString("?")
		}
		out.WriteString(": ")
		out.WriteString(fieldType)
		out.WriteString(";\n")
	}
	out.WriteString("}")
	return out.String(), nil
}

type tsField struct {
	name     string
	typ      reflect.Type
	optional bool
}

func tsStructFields(typ reflect.Type) []tsField {
	var fields []tsField
	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		if field.PkgPath != "" {
			continue
		}
		name, optional, ok := tsJSONFieldName(field)
		if !ok {
			continue
		}
		if field.Anonymous && name == field.Name && field.Type.Kind() == reflect.Struct {
			fields = append(fields, tsStructFields(field.Type)...)
			continue
		}
		fields = append(fields, tsField{name: name, typ: field.Type, optional: optional})
	}
	sort.SliceStable(fields, func(i, j int) bool { return fields[i].name < fields[j].name })
	return fields
}

func tsJSONFieldName(field reflect.StructField) (string, bool, bool) {
	tag := field.Tag.Get("json")
	if tag == "-" {
		return "", false, false
	}
	if tag == "" {
		return field.Name, false, true
	}
	parts := strings.Split(tag, ",")
	name := parts[0]
	if name == "" {
		name = field.Name
	}
	optional := false
	for _, opt := range parts[1:] {
		if opt == "omitempty" {
			optional = true
			break
		}
	}
	return name, optional, true
}

func tsPropertyKey(key string) string {
	if isTSIdentifier(key) {
		return key
	}
	bytes, _ := json.Marshal(key)
	return string(bytes)
}

func isTSIdentifier(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		if i == 0 {
			if !(r == '_' || r == '$' || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z')) {
				return false
			}
			continue
		}
		if !(r == '_' || r == '$' || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}

func escapeSingleQuoted(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), `'`, `\'`)
}
