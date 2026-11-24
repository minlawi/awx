package main

import rego.v1

# Helper 1: Match Lo0, lo0, Loopback0, or "Loopback 0"
is_lo0(name) if {
	replace(lower(name), " ", "") in {"lo0", "loopback0"}
}

# Helper 2: Get just the IP address (works for both Cisco and Juniper formats)
# "10.100.100.1 255.255.255.255" -> "10.100.100.1"
# "10.255.10.3/32"               -> "10.255.10.3"
get_ip(raw) := split(split(trim_space(raw), " ")[0], "/")[0]

# Rule 1: Lo0 / Loopback 0 must use a /32 mask
deny contains msg if {
	some file in input
	some iface in file.contents.loopback_interfaces
	is_lo0(iface.name)

	ip_str := trim_space(iface.ipv4)
	not endswith(ip_str, "/32")
	not endswith(ip_str, " 255.255.255.255")

	msg := sprintf("%s (%s): '%s' must use a /32 or 255.255.255.255 mask", [
		file.path, iface.name, iface.ipv4,
	])
}

# Rule 2: Fail if two loopback interfaces share the same IP
deny contains msg if {
	some file1 in input
	some file2 in input
	some i, iface1 in file1.contents.loopback_interfaces
	some j, iface2 in file2.contents.loopback_interfaces

	# Avoid comparing an interface to itself or reporting the same pair twice
	sprintf("%s:%d", [file1.path, i]) < sprintf("%s:%d", [file2.path, j])

	ip := get_ip(iface1.ipv4)
	ip == get_ip(iface2.ipv4)

	msg := sprintf("Duplicate loopback IP '%s' in %s (%s) and %s (%s)", [
		ip, file1.path, iface1.name, file2.path, iface2.name,
	])
}

# Rule 3: Fail if a loopback IP conflicts with hosts.ini or any other inventory file
deny contains msg if {
	some lb_file in input
	some iface in lb_file.contents.loopback_interfaces
	ip := get_ip(iface.ipv4)

	some other_file in input
	other_file.path != lb_file.path
	not other_file.contents.loopback_interfaces

	walk(other_file.contents, [_, val])
	is_string(val)
	get_ip(val) == ip

	msg := sprintf("Conflict: loopback IP '%s' in %s is already used in %s", [
		ip, lb_file.path, other_file.path,
	])
}