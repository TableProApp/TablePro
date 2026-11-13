using TablePro.Interop;

namespace TablePro.App.Model;

// The share sheet's reads for its current choices. Each choice starts a round; a summary or a preview of an older round
// is dropped when it lands, and a result is shared only once this round's summary and preview have both landed.
public sealed class ShareRounds
{
    public int Round { get; private set; }

    // Null until this round's summary lands.
    public ShareSummary? Summary { get; private set; }

    // This round's preview is on screen, so the rows shown are the ones the link sends.
    public bool PreviewShown { get; private set; }

    public int Begin()
    {
        Round++;
        Summary = null;
        PreviewShown = false;
        return Round;
    }

    public bool IsCurrent(int round) => round == Round;

    public bool TakeSummary(int round, ShareSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        if (round != Round)
        {
            return false;
        }

        Summary = summary;
        return true;
    }

    // Only after this round's summary said the rows can go; a preview never stands for rows too large to send.
    public bool TakePreview(int round)
    {
        if (round != Round || Summary is not { TooLarge: null })
        {
            return false;
        }

        PreviewShown = true;
        return true;
    }

    public ShareReadiness Readiness(SharePlan plan, ShareColumns? columns)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var readiness = plan.Readiness(columns, Summary);
        return readiness == ShareReadiness.Ready && plan.Kind == ShareKind.Result && !PreviewShown
            ? ShareReadiness.Reading
            : readiness;
    }
}
