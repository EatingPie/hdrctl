SWIFTC ?= swiftc

.PHONY: all clean hdrctl hdrctl-private

all: hdrctl hdrctl-private

hdrctl: hdrctl.swift
	$(SWIFTC) hdrctl.swift -o hdrctl

clean:
	rm -f hdrctl hdrctl-private
