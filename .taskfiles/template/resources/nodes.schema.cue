package config

import (
	"net"
	"list"
)

#Config: {
	nodes: [...#Node]
	_nodes_check: {
		name: list.UniqueItems() & [for item in nodes {item.name}]
		address: list.UniqueItems() & [for item in nodes {item.address}]
		mac_addr: list.UniqueItems() & [for item in nodes {item.mac_addr}]
	}
}

#Node: {
	name:          =~"^[a-z0-9][a-z0-9\\-]{0,61}[a-z0-9]$|^[a-z0-9]$" & !="global" & !="controller" & !="worker"
	address:       net.IPv4
	controller:    bool
	disk:          string
	mac_addr:      =~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$"
	schematic_id:  =~"^[a-z0-9]{64}$"
	mtu?:          >=1450 & <=9000
	secureboot?:   bool
	encrypt_disk?: bool
	longhorn?:     #Longhorn
}

// Optional per-node Longhorn storage config. When set, the talconfig template
// emits node labels/annotations that Longhorn reads (createDefaultDiskLabeledNodes
// is enabled in the HelmRelease) to create the node's disks at registration.
// Disk keys mirror Longhorn's default-disks-config annotation schema verbatim.
#Longhorn: {
	disks: [...#LonghornDisk]
	node_tags?: [...string]
}

#LonghornDisk: {
	path:             string
	allowScheduling?: bool
	storageReserved?: int & >=0
	tags?: [...string]
}

#Config
