// Package fs provides Suji file-system APIs through the core IPC channel.
package fs

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

func ReadFile(path string) string {
	return suji.Invoke("__core__", buildReadFileRequest(path))
}

func WriteFile(path, text string) string {
	return suji.Invoke("__core__", buildWriteFileRequest(path, text))
}

func Stat(path string) string {
	return suji.Invoke("__core__", buildStatRequest(path))
}

func Mkdir(path string, recursive bool) string {
	return suji.Invoke("__core__", buildMkdirRequest(path, recursive))
}

func ReadDir(path string) string {
	return suji.Invoke("__core__", buildReadDirRequest(path))
}

// Rm removes a path. recursive=true for directory tree, force=true to ignore not-found
// (Node fs.rm({recursive,force}) semantics).
func Rm(path string, recursive, force bool) string {
	return suji.Invoke("__core__", buildRmRequest(path, recursive, force))
}

func buildReadFileRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_read_file","path":"%s"}`, jsonesc.Full(path))
}

func buildWriteFileRequest(path, text string) string {
	return fmt.Sprintf(`{"cmd":"fs_write_file","path":"%s","text":"%s"}`, jsonesc.Full(path), jsonesc.Full(text))
}

func buildStatRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_stat","path":"%s"}`, jsonesc.Full(path))
}

func buildMkdirRequest(path string, recursive bool) string {
	return fmt.Sprintf(`{"cmd":"fs_mkdir","path":"%s","recursive":%t}`, jsonesc.Full(path), recursive)
}

func buildReadDirRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_readdir","path":"%s"}`, jsonesc.Full(path))
}

func buildRmRequest(path string, recursive, force bool) string {
	return fmt.Sprintf(`{"cmd":"fs_rm","path":"%s","recursive":%t,"force":%t}`, jsonesc.Full(path), recursive, force)
}
