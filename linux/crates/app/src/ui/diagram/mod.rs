//! A schema's entity-relationship diagram: each table as a card of its
//! columns, each foreign key as a line between the rows it joins.
//!
//! The tab reads the schema's tables in the background with Stop, lays
//! them out by their keys, and draws them on a canvas that pans, zooms,
//! moves cards and exports PNG and SVG. A focusable widget stands where
//! each card is drawn, so the keyboard and a screen reader move from
//! table to table and hear each one's columns and the tables it joins.

mod canvas;
mod canvas_imp;
mod canvas_input;
mod card_text;
mod describe;
mod draw;
#[cfg(test)]
mod engines;
mod export;
mod fetch;
mod layout;
mod model;
mod node;
mod palette;
mod scene;
mod tab;
mod tab_imp;
#[cfg(test)]
mod tests;
mod zoom;

pub(crate) use self::tab::{DiagramTab, DiagramTabInit};
