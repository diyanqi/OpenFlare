//go:build windows

package main

import (
	"context"
	"errors"
	"log/slog"

	"golang.org/x/sys/windows/svc"
)

const windowsServiceName = "OpenFlareAgent"

func runAsPlatformService(configPath string) (bool, error) {
	interactive, err := svc.IsAnInteractiveSession()
	if err != nil {
		return true, err
	}
	if interactive {
		return false, nil
	}
	return true, svc.Run(windowsServiceName, &agentService{configPath: configPath})
}

type agentService struct {
	configPath string
}

func (s *agentService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 1)
	go func() {
		errCh <- runAgentProcess(ctx, s.configPath)
	}()

	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-errCh:
			if err != nil && !errors.Is(err, context.Canceled) {
				slog.Error("agent service process stopped unexpectedly", "error", err)
				return false, 1
			}
			return false, 0
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				status <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				err := <-errCh
				if err != nil && !errors.Is(err, context.Canceled) {
					slog.Error("agent service stop failed", "error", err)
					return false, 1
				}
				return false, 0
			}
		}
	}
}
