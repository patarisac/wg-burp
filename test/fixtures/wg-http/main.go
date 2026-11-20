// Disposable CI peer: its IP exists inside an independent userspace TCP/IP stack.
package main

import (
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func request(addr netip.Addr, url string, config []byte) error {
	tun, network, err := netstack.CreateNetTUN([]netip.Addr{addr}, nil, 1380)
	if err != nil {
		return err
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	defer dev.Close()
	if err := dev.IpcSet(string(config)); err != nil {
		return fmt.Errorf("configure WireGuard peer: %w", err)
	}
	if err := dev.Up(); err != nil {
		return fmt.Errorf("start WireGuard peer: %w", err)
	}
	transport := &http.Transport{DialContext: network.DialContext, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected HTTP status: %s", resp.Status)
	}
	_, err = io.Copy(os.Stdout, io.LimitReader(resp.Body, 4096))
	return err
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: wg-http <client IPv4> <test URL> < <UAPI configuration>")
		os.Exit(2)
	}
	addr, err := netip.ParseAddr(os.Args[1])
	if err == nil {
		var config []byte
		config, err = io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err == nil {
			err = request(addr, os.Args[2], config)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
