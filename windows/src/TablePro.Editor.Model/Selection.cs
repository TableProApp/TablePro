namespace TablePro.Editor.Model;

// PreferredColumn is the visual column vertical moves aim for, -1 when unset.
public readonly record struct Selection(int Anchor, int Active, int PreferredColumn = -1)
{
    public int Start => Math.Min(Anchor, Active);

    public int End => Math.Max(Anchor, Active);

    public int Length => End - Start;

    public bool IsEmpty => Anchor == Active;

    public bool IsReversed => Active < Anchor;

    public static Selection Caret(int offset) => new(offset, offset);

    public Selection WithActive(int active, bool extend) => extend ? this with { Active = active, PreferredColumn = -1 }
        : new Selection(active, active);

    public bool Contains(int offset) => offset >= Start && offset <= End;

    // An offset inside the replaced text, or at the point of an insert, ends up after the new text.
    public Selection Map(TextChange change) =>
        new(MapOffset(Anchor, change), MapOffset(Active, change), PreferredColumn);

    public static int MapOffset(int offset, TextChange change)
    {
        var removedEnd = change.Offset + change.RemovedLength;
        if (offset < change.Offset)
        {
            return offset;
        }
        if (offset >= removedEnd && (change.RemovedLength > 0 || offset > change.Offset))
        {
            return offset - change.RemovedLength + change.InsertedLength;
        }
        return change.Offset + change.InsertedLength;
    }
}
