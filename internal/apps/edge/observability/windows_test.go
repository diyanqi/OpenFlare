//go:build windows

package observability

import "testing"

func TestWindowsSystemMetrics(t *testing.T) {
	total, used := ReadMemInfo()
	if total <= 0 || used < 0 || used > total {
		t.Fatalf("ReadMemInfo() = (%d, %d), want positive total and bounded used value", total, used)
	}

	diskTotal, diskUsed := StatFilesystem(t.TempDir())
	if diskTotal <= 0 || diskUsed < 0 || diskUsed > diskTotal {
		t.Fatalf("StatFilesystem() = (%d, %d), want positive total and bounded used value", diskTotal, diskUsed)
	}
}
