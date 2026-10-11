//! Defines types to use with the vector sets commands.

use crate::{RedisWrite, ToRedisArgs};

/// Options for the VSIM command
///
/// # Example
/// ```rust,no_run
/// use redis::{Commands, RedisResult, vector_sets::*};
/// fn search_similar_vectors(
///     con: &mut redis::Connection,
///     key: &str,
///     element: &str,
/// ) -> RedisResult<redis::Value> {
///     let opts = VSimOptions::default()
///         .set_with_scores(true)
///         .set_count(10)
///         .set_search_exploration_factor(100)
///         .set_filter_expression(".size == \"large\"")
///         .set_max_filtering_effort(10)
///         .set_truth(true)
///         .set_no_thread(true);
///     con.vsim_options(key, VectorSimilaritySearchInput::Element(element), &opts)
/// }
/// ```
#[derive(Clone, Default)]
pub struct VSimOptions {
    /// Include similarity scores in the results
    with_scores: bool,
    /// Limit the number of results returned
    count: Option<usize>,
    /// Controls the search effort. Higher values explore more nodes, improving recall at the cost of speed.
    /// Typical values range from 50 to 1000.
    search_exploration_factor: Option<usize>,
    /// JSON filter expression to apply to the results
    filter: Option<String>,
    /// Limits the number of filtering attempts for the FILTER expression.
    /// The accuracy improves the with higher values, but the search may take longer.
    filter_max_effort: Option<usize>,
    /// Forces an exact linear scan of all elements, bypassing the HNSW graph.
    /// Use for benchmarking or to calculate recall. This is significantly slower (O(N)).
    truth: bool,
    /// Executes the search in the main thread instead of a background thread.
    /// Useful for small vector sets or benchmarks. This may block the server during execution!
    no_thread: bool,
}

impl VSimOptions {
    /// Include similarity scores in the results
    pub fn set_with_scores(mut self, enabled: bool) -> Self {
        self.with_scores = enabled;
        self
    }

    /// Limit the number of results returned
    pub fn set_count(mut self, count: usize) -> Self {
        self.count = Some(count);
        self
    }

    /// Set the search exploration factor
    pub fn set_search_exploration_factor(mut self, factor: usize) -> Self {
        self.search_exploration_factor = Some(factor);
        self
    }

    /// Set a JSON filter expression
    pub fn set_filter_expression<S: Into<String>>(mut self, expression: S) -> Self {
        self.filter = Some(expression.into());
        self
    }

    /// Set the maximum filtering effort
    pub fn set_max_filtering_effort(mut self, effort: usize) -> Self {
        self.filter_max_effort = Some(effort);
        self
    }

    /// Enable/disable exact linear scan of all elements
    pub fn set_truth(mut self, enabled: bool) -> Self {
        self.truth = enabled;
        self
    }

    /// Enable/disable multi-threading
    pub fn set_no_thread(mut self, enabled: bool) -> Self {
        self.no_thread = enabled;
        self
    }
}

impl ToRedisArgs for VSimOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if self.with_scores {
            out.write_arg(b"WITHSCORES");
        }

        if let Some(count) = self.count {
            out.write_arg(b"COUNT");
            out.write_arg_fmt(count);
        }

        if let Some(ef) = self.search_exploration_factor {
            out.write_arg(b"EF");
            out.write_arg_fmt(ef);
        }

        if let Some(ref filter) = self.filter {
            out.write_arg(b"FILTER");
            out.write_arg(filter.as_bytes());
        }

        if let Some(filter_ef) = self.filter_max_effort {
            out.write_arg(b"FILTER-EF");
            out.write_arg_fmt(filter_ef);
        }

        if self.truth {
            out.write_arg(b"TRUTH");
        }

        if self.no_thread {
            out.write_arg(b"NOTHREAD");
        }
    }
}

/// Input data formats that can be used to generate vector embeddings:
///
/// - 32-bit floats
/// - 64-bit floats
/// - Strings (e.g., numbers as strings)
#[derive(Clone)]
#[non_exhaustive]
pub enum EmbeddingInput<'a> {
    /// 32-bit floating point input
    Float32(&'a [f32]),
    /// 64-bit floating point input
    Float64(&'a [f64]),
    /// String input (e.g., numbers as strings)
    String(&'a [&'a str]),
}

impl ToRedisArgs for EmbeddingInput<'_> {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            EmbeddingInput::Float32(vector) => {
                out.write_arg_fmt(vector.len());
                for &f in *vector {
                    out.write_arg_fmt(f);
                }
            }
            EmbeddingInput::Float64(vector) => {
                out.write_arg_fmt(vector.len());
                for &f in *vector {
                    out.write_arg_fmt(f);
                }
            }
            EmbeddingInput::String(vector) => {
                out.write_arg_fmt(vector.len());
                for v in *vector {
                    v.write_redis_args(out);
                }
            }
        }
    }
}

/// Represents different ways to input data for vector add commands
#[derive(Clone)]
#[non_exhaustive]
pub enum VectorAddInput<'a> {
    /// Binary representation of 32-bit floating point values
    Fp32(&'a [f32]),
    /// A list of values whose types are supported for embedding generation
    Values(EmbeddingInput<'a>),
}

impl ToRedisArgs for VectorAddInput<'_> {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            VectorAddInput::Fp32(vector) => {
                use std::io::Write;
                out.write_arg(b"FP32");
                let mut writer = out.writer_for_next_arg();
                for &f in *vector {
                    writer.write_all(&f.to_le_bytes()).unwrap();
                }
            }
            VectorAddInput::Values(embedding_input) => {
                out.write_arg(b"VALUES");
                embedding_input.write_redis_args(out);
            }
        }
    }
}

/// Quantization options for vector storage
#[derive(Clone, Copy, Debug)]
#[non_exhaustive]
pub enum VectorQuantization {
    /// In the first VADD call for a given key, NOQUANT forces the vector to be created without int8 quantization, which is otherwise the default.
    NoQuant,
    /// Forces the vector to use signed 8-bit quantization.
    /// This is the default, and the option only exists to make sure to check at insertion time that the vector set is of the same format.
    Q8,
    /// Forces the vector to use binary quantization instead of int8.
    /// This is much faster and uses less memory, but impacts the recall quality.
    Bin,
}

/// Options for the VADD command
///
/// # Example
/// ```rust,no_run
/// use redis::{Commands, RedisResult, vector_sets::*};
/// fn add_vector(
///     con: &mut redis::Connection,
///     key: &str,
///     vector: &[f64],
///     element: &str,
/// ) -> RedisResult<bool> {
///     let opts = VAddOptions::default()
///         .set_reduction_dimension(5)
///         .set_check_and_set_style(true)
///         .set_quantization(VectorQuantization::Q8)
///         .set_build_exploration_factor(300)
///         .set_attributes(serde_json::json!({"name": "Vector attribute name", "description": "Vector attribute description"}))
///         .set_max_number_of_links(16);
///     con.vadd_options(key, VectorAddInput::Values(EmbeddingInput::Float64(vector)), element, &opts)
/// }
/// ```
#[derive(Clone, Default)]
pub struct VAddOptions {
    /// Implements random projection to reduce the dimensionality of the vector.
    /// The projection matrix is saved and reloaded along with the vector set.
    pub(crate) reduction_dimension: Option<usize>,
    /// Performs the operation partially using threads, in a check-and-set style.
    /// The neighbor candidates collection, which is slow, is performed in the background, while the command is executed in the main thread.
    enable_check_and_set_style: bool,
    /// The quantization to be used. If no quantization is provided, the default value, Q8 (signed 8-bit), will be used.
    vector_quantization: Option<VectorQuantization>,
    /// Plays a role in the effort made to find good candidates when connecting the new node to the existing Hierarchical Navigable Small World (HNSW) graph.
    /// The default is 200. Using a larger value may help in achieving a better recall.
    build_exploration_factor: Option<usize>,
    /// Assigns attributes from a JavaScript object to a newly created entry or updates existing attributes.
    attributes: Option<serde_json::Value>,
    /// The maximum number of connections that each node of the graph will have with other nodes.
    /// The default is 16. More connections means more memory, but provides for more efficient graph exploration.
    max_number_of_links: Option<usize>,
}

impl VAddOptions {
    /// Set reduction dimension value
    pub fn set_reduction_dimension(mut self, dimension: usize) -> Self {
        self.reduction_dimension = Some(dimension);
        self
    }

    /// Set the CAS (check-and-set) style flag
    pub fn set_check_and_set_style(mut self, cas_enabled: bool) -> Self {
        self.enable_check_and_set_style = cas_enabled;
        self
    }

    /// Set the quantization mode
    pub fn set_quantization(mut self, vector_quantization: VectorQuantization) -> Self {
        self.vector_quantization = Some(vector_quantization);
        self
    }

    /// Set the build exploration factor
    pub fn set_build_exploration_factor(mut self, build_exploration_factor: usize) -> Self {
        self.build_exploration_factor = Some(build_exploration_factor);
        self
    }

    /// Set attributes as JSON string
    pub fn set_attributes(mut self, attributes: serde_json::Value) -> Self {
        self.attributes = Some(attributes);
        self
    }

    /// Set the maximum number of links
    pub fn set_max_number_of_links(mut self, max_number_of_links: usize) -> Self {
        self.max_number_of_links = Some(max_number_of_links);
        self
    }
}

impl ToRedisArgs for VAddOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if self.enable_check_and_set_style {
            out.write_arg(b"CAS");
        }

        if let Some(ref quantization) = self.vector_quantization {
            match quantization {
                VectorQuantization::NoQuant => out.write_arg(b"NOQUANT"),
                VectorQuantization::Q8 => out.write_arg(b"Q8"),
                VectorQuantization::Bin => out.write_arg(b"BIN"),
            }
        }

        if let Some(exploration_factor) = self.build_exploration_factor {
            out.write_arg(b"EF");
            out.write_arg_fmt(exploration_factor);
        }

        if let Some(ref attrs) = self.attributes {
            out.write_arg(b"SETATTR");
            out.write_arg(&serde_json::to_vec(&attrs).unwrap());
        }

        if let Some(max_links) = self.max_number_of_links {
            out.write_arg(b"M");
            out.write_arg_fmt(max_links);
        }
    }
}

/// Options for the VEMB command
///
/// # Example
/// ```rust,no_run
/// use redis::{Commands, RedisResult, vector_sets::VEmbOptions};
/// fn get_vector_embedding(
///     con: &mut redis::Connection,
///     key: &str,
///     element: &str,
/// ) -> RedisResult<redis::Value> {
///     let opts = VEmbOptions::default().set_raw_representation(true);
///     con.vemb_options(key, element, &opts)
/// }
/// ```
#[derive(Clone, Default)]
pub struct VEmbOptions {
    /// Returns the raw internal representation of the approximate vector associated with a given element in the vector set
    raw_representation: bool,
}

impl VEmbOptions {
    /// Set the raw representation flag
    pub fn set_raw_representation(mut self, enabled: bool) -> Self {
        self.raw_representation = enabled;
        self
    }
}

impl ToRedisArgs for VEmbOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if self.raw_representation {
            out.write_arg(b"RAW");
        }
    }
}

/// Represents different ways to input query data for vector similarity search commands
#[cfg_attr(docsrs, doc(cfg(feature = "vector-sets")))]
#[derive(Clone)]
#[non_exhaustive]
pub enum VectorSimilaritySearchInput<'a> {
    /// Binary representation of 32-bit floating point values to use as a reference
    Fp32(&'a [f32]),
    /// List of values to use as a reference
    Values(EmbeddingInput<'a>),
    /// Element to use as a reference
    Element(&'a str),
}

impl ToRedisArgs for VectorSimilaritySearchInput<'_> {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            VectorSimilaritySearchInput::Fp32(vector) => {
                use std::io::Write;
                out.write_arg(b"FP32");
                let mut writer = out.writer_for_next_arg();
                for &f in *vector {
                    writer.write_all(&f.to_le_bytes()).unwrap();
                }
            }
            VectorSimilaritySearchInput::Values(embedding_input) => {
                out.write_arg(b"VALUES");
                embedding_input.write_redis_args(out);
            }
            VectorSimilaritySearchInput::Element(element) => {
                out.write_arg(b"ELE");
                element.write_redis_args(out);
            }
        }
    }
}
