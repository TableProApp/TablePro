// A backend row is an open bag of fields, as the JSON both backends print: the projection reads the keys it knows
// and ignores the rest, so a newer backend that adds a field does not break the build.
global using LedgerRow = System.Collections.Generic.Dictionary<string, object?>;
