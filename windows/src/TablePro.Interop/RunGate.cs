namespace TablePro.Interop;

// What Safe Mode lets an editor run do. An editor sends its text whole, so Refused keeps the whole run back;
// Confirm holds each statement to ask about first, as it would run.
public sealed record RunGate(bool Refused, IReadOnlyList<string> Confirm, bool Destructive);
