using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TlsRemedyTests
{
    [Theory]
    [InlineData(TlsFailure.ServerRefusedTls)]
    [InlineData(TlsFailure.ServerRequiresTls)]
    [InlineData(TlsFailure.ServerRefusedStrict)]
    [InlineData(TlsFailure.ServerRequiresStrict)]
    public void AFailureAModeChangeFixesOffersChangeEncryption(TlsFailure failure) =>
        Assert.Equal(TlsRemedy.ChangeEncryption, TlsRemedies.For(failure, serverNameShown: true));

    [Fact]
    public void ACertificateTheClientCanTrustOrRenameOffersThatRow()
    {
        Assert.Equal(TlsRemedy.ChooseCaCertificate, TlsRemedies.For(TlsFailure.UnknownIssuer, serverNameShown: true));
        Assert.Equal(TlsRemedy.SetServerName, TlsRemedies.For(TlsFailure.NameMismatch, serverNameShown: true));
        Assert.Null(TlsRemedies.For(TlsFailure.NameMismatch, serverNameShown: false));
    }

    [Theory]
    [InlineData(TlsFailure.Expired)]
    [InlineData(TlsFailure.Revoked)]
    [InlineData(TlsFailure.Other)]
    public void AFailureOnlyTheServerCanFixOffersNothing(TlsFailure failure) =>
        Assert.Null(TlsRemedies.For(failure, serverNameShown: true));
}
