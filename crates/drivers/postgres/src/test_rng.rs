pub(crate) struct Xorshift(u64);

impl Xorshift {
    pub(crate) fn new(seed: u64) -> Self {
        Self(seed)
    }

    pub(crate) fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    pub(crate) fn bytes(&mut self, max_len: u64) -> Vec<u8> {
        let length = self.next() % (max_len + 1);
        let interesting = [0_u8, 1, 2, 3, 4, 8, 0x10, 0x7f, 0x80, 0xff];
        (0..length)
            .map(|_| {
                let roll = self.next();
                if roll.is_multiple_of(3) {
                    interesting[(roll >> 8) as usize % interesting.len()]
                } else {
                    (roll >> 16) as u8
                }
            })
            .collect()
    }
}
