package tui

// Cksum is the POSIX cksum(1) CRC over data: CRC-32 with polynomial
// 0x04C11DB7 (MSB first, no reflection, zero init), the length appended
// LSB-first, ones-complemented. The fleet's inbox fingerprints a pane's
// capture with `cksum`, and the Go inbox must produce the same number so
// `agent-fleet answer --fp` accepts it.
func Cksum(data []byte) uint32 {
	var crc uint32
	update := func(b byte) {
		crc ^= uint32(b) << 24
		for i := 0; i < 8; i++ {
			if crc&0x80000000 != 0 {
				crc = (crc << 1) ^ 0x04C11DB7
			} else {
				crc <<= 1
			}
		}
	}
	for _, b := range data {
		update(b)
	}
	for n := len(data); n != 0; n >>= 8 {
		update(byte(n & 0xff))
	}
	return ^crc
}
