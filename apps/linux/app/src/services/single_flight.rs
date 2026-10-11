use std::cell::Cell;
use std::rc::Rc;

#[derive(Clone, Default)]
pub struct SingleFlight(Rc<Cell<bool>>);

pub struct Flight(Rc<Cell<bool>>);

impl SingleFlight {
    pub fn try_begin(&self) -> Option<Flight> {
        if self.0.replace(true) {
            return None;
        }
        Some(Flight(self.0.clone()))
    }
}

impl Drop for Flight {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_operation_is_refused_until_the_first_finishes() {
        let gate = SingleFlight::default();
        let first = gate.try_begin().expect("idle gate admits an operation");
        assert!(gate.try_begin().is_none());
        assert!(gate.clone().try_begin().is_none());
        drop(first);
        assert!(gate.try_begin().is_some());
    }
}
