//go:build windows

package observability

import (
	"math"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32                 = windows.NewLazySystemDLL("kernel32.dll")
	globalMemoryStatusExProc = kernel32.NewProc("GlobalMemoryStatusEx")
	getSystemTimesProc       = kernel32.NewProc("GetSystemTimes")
	getTickCount64Proc       = kernel32.NewProc("GetTickCount64")
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

type windowsFileTime struct {
	LowDateTime  uint32
	HighDateTime uint32
}

func ReadLinuxOSRelease() (string, string) {
	return runtime.GOOS, ""
}

func ReadLinuxCPUModel() string {
	return ""
}

func ReadMemInfo() (int64, int64) {
	status := memoryStatusEx{Length: uint32(unsafe.Sizeof(memoryStatusEx{}))}
	result, _, _ := globalMemoryStatusExProc.Call(uintptr(unsafe.Pointer(&status)))
	if result == 0 {
		return 0, 0
	}
	total := boundedUint64ToInt64(status.TotalPhys)
	available := boundedUint64ToInt64(status.AvailPhys)
	used := total - available
	if used < 0 {
		used = 0
	}
	return total, used
}

func ReadLinuxUptimeSeconds() int64 {
	result, _, _ := getTickCount64Proc.Call()
	return int64(uint64(result) / 1000)
}

func ReadLinuxCPUStat() (uint64, uint64) {
	var idle, kernel, user windowsFileTime
	result, _, _ := getSystemTimesProc.Call(
		uintptr(unsafe.Pointer(&idle)),
		uintptr(unsafe.Pointer(&kernel)),
		uintptr(unsafe.Pointer(&user)),
	)
	if result == 0 {
		return 0, 0
	}
	idleTicks := fileTimeToUint64(idle)
	totalTicks := fileTimeToUint64(kernel) + fileTimeToUint64(user)
	return totalTicks, idleTicks
}

func ReadLinuxNetworkTotals() (int64, int64) {
	return 0, 0
}

func ReadLinuxDiskTotals() (int64, int64) {
	return 0, 0
}

func StatFilesystem(path string) (int64, int64) {
	path = strings.TrimSpace(path)
	if path == "" {
		current, err := filepath.Abs(".")
		if err != nil {
			return 0, 0
		}
		path = filepath.VolumeName(current) + `\`
	}
	pathPtr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0
	}
	var freeBytes, totalBytes, totalFreeBytes uint64
	if err = windows.GetDiskFreeSpaceEx(pathPtr, &freeBytes, &totalBytes, &totalFreeBytes); err != nil {
		return 0, 0
	}
	free := boundedUint64ToInt64(totalFreeBytes)
	total := boundedUint64ToInt64(totalBytes)
	used := total - free
	if used < 0 {
		used = 0
	}
	return total, used
}

func ReadFirstLine(string) string {
	return ""
}

func fileTimeToUint64(value windowsFileTime) uint64 {
	return uint64(value.HighDateTime)<<32 | uint64(value.LowDateTime)
}

func boundedUint64ToInt64(value uint64) int64 {
	if value > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(value)
}
