use redis::Value as Reply;

// The numbered database an editor's link is on, followed from the replies to what the tab sends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SessionDatabase {
    current: u32,
    block: Option<Block>,
}

// A MULTI's commands so far: a SELECT in it moves the link only if EXEC runs it and it answers OK.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Block {
    queued: usize,
    selects: Vec<(usize, u32)>,
}

impl SessionDatabase {
    pub(crate) fn new(current: u32) -> Self {
        Self { current, block: None }
    }

    pub(crate) fn current(&self) -> u32 {
        self.current
    }

    pub(crate) fn moved(&mut self, index: u32) {
        self.current = index;
    }

    pub(crate) fn observe(&mut self, arguments: &[Vec<u8>], reply: &Reply) {
        let Some(name) = arguments.first().map(|name| name.to_ascii_uppercase()) else {
            return;
        };
        if matches!(reply, Reply::SimpleString(status) if status == "QUEUED") {
            if let Some(block) = &mut self.block {
                if name == b"SELECT"
                    && let Some(index) = select_index(arguments)
                {
                    block.selects.push((block.queued, index));
                }
                block.queued += 1;
            }
            return;
        }
        match (name.as_slice(), reply) {
            (b"MULTI", Reply::Okay) => self.block = Some(Block::default()),
            (b"SELECT", Reply::Okay) => {
                if let Some(index) = select_index(arguments) {
                    self.current = index;
                }
            }
            (b"EXEC", Reply::Array(answers)) => {
                for (position, index) in self.block.take().map(|block| block.selects).unwrap_or_default() {
                    if matches!(answers.get(position), Some(Reply::Okay)) {
                        self.current = index;
                    }
                }
            }
            (b"EXEC", Reply::ServerError(error)) if error.code() == "EXECABORT" => self.block = None,
            // A refused EXEC or DISCARD leaves the block open, and so does a nested MULTI.
            (_, Reply::ServerError(_)) => {}
            (b"EXEC" | b"DISCARD", _) => self.block = None,
            (b"RESET", _) => {
                self.current = 0;
                self.block = None;
            }
            _ => {}
        }
    }
}

// The server takes only a canonical integer, so whatever it accepted parses.
fn select_index(arguments: &[Vec<u8>]) -> Option<u32> {
    std::str::from_utf8(arguments.get(1)?).ok()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(line: &str) -> Vec<Vec<u8>> {
        line.split(' ').map(|word| word.as_bytes().to_vec()).collect()
    }

    fn queued() -> Reply {
        Reply::SimpleString("QUEUED".to_owned())
    }

    fn error(line: &str) -> Reply {
        redis::parse_redis_value(format!("-{line}\r\n").as_bytes()).unwrap()
    }

    fn after(start: u32, steps: &[(&str, Reply)]) -> u32 {
        let mut database = SessionDatabase::new(start);
        for (line, reply) in steps {
            database.observe(&args(line), reply);
        }
        database.current()
    }

    #[test]
    fn a_select_the_server_accepted_moves_the_link() {
        assert_eq!(after(0, &[("SELECT 3", Reply::Okay)]), 3);
        assert_eq!(after(0, &[("select 3", Reply::Okay)]), 3);
        assert_eq!(after(2, &[("SELECT 99", error("ERR DB index is out of range"))]), 2);
    }

    #[test]
    fn a_queued_select_moves_the_link_only_when_exec_runs_it() {
        let block = |end: (&'static str, Reply)| {
            vec![
                ("MULTI", Reply::Okay),
                ("SET k v", queued()),
                ("SELECT 4", queued()),
                end,
            ]
        };

        assert_eq!(
            after(1, &block(("EXEC", Reply::Array(vec![Reply::Okay, Reply::Okay])))),
            4
        );
        assert_eq!(after(1, &block(("DISCARD", Reply::Okay))), 1);
        assert_eq!(after(1, &block(("EXEC", Reply::Nil))), 1);
        assert_eq!(after(1, &block(("EXEC", error("EXECABORT Transaction discarded")))), 1);
        assert_eq!(after(1, &block(("RESET", Reply::SimpleString("RESET".to_owned())))), 0);
    }

    #[test]
    fn a_queued_select_exec_answers_with_an_error_leaves_the_link() {
        let steps = [
            ("MULTI", Reply::Okay),
            ("SELECT 99", queued()),
            ("EXEC", Reply::Array(vec![error("ERR DB index is out of range")])),
        ];

        assert_eq!(after(1, &steps), 1);
    }

    #[test]
    fn a_refused_command_takes_no_place_in_the_block() {
        let steps = [
            ("MULTI", Reply::Okay),
            ("NOSUCH", error("ERR unknown command")),
            ("SELECT 5", queued()),
            ("EXEC", Reply::Array(vec![Reply::Okay])),
        ];

        assert_eq!(after(0, &steps), 5);
    }

    #[test]
    fn a_refused_exec_keeps_the_block_for_the_exec_after_it() {
        let steps = [
            ("MULTI", Reply::Okay),
            ("SELECT 6", queued()),
            ("EXEC extra", error("ERR wrong number of arguments for 'exec' command")),
            ("EXEC", Reply::Array(vec![Reply::Okay])),
        ];

        assert_eq!(after(0, &steps), 6);
    }

    #[test]
    fn reset_returns_the_link_to_database_zero() {
        assert_eq!(after(7, &[("RESET", Reply::SimpleString("RESET".to_owned()))]), 0);
        assert_eq!(after(7, &[("RESET extra", error("ERR wrong number of arguments"))]), 7);
    }
}
