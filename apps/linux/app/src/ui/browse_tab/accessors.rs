use super::*;

impl BrowseTab {
    pub fn current_offset(&self) -> u64 {
        self.current_offset
    }

    pub fn begin_page_request(&self) -> BrowsePageRequest {
        self.page_requests.begin(self.current_offset)
    }

    pub fn accepts_page_request(&self, request: BrowsePageRequest) -> bool {
        self.page_requests.accepts(request, self.current_offset)
    }

    pub fn begin_row_count_request(&self) -> BrowseRowCountRequest {
        self.row_count_requests.begin()
    }

    pub fn total_rows(&self) -> Option<u64> {
        self.current_total_rows
    }

    pub fn page_size(&self) -> u64 {
        self.page_size
    }

    pub fn current_sort(&self) -> Option<(usize, bool)> {
        self.current_sort
    }

    pub fn current_filter(&self) -> &tablepro_core::FilterSet {
        &self.current_filter
    }

    pub fn keyset_cursor(&self) -> Option<&[tablepro_core::Value]> {
        self.keyset_cursor.as_deref()
    }

    pub fn driver_id(&self) -> &str {
        &self.driver_id
    }
}
