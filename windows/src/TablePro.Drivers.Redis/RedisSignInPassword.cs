using StackExchange.Redis.Configuration;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis;

/// <summary>
/// The password of an ElastiCache IAM sign-in, a token that is accepted for fifteen minutes. The client library reads
/// <see cref="Password"/> each time it opens a connection, so a reconnect an hour after the first one signs in with a
/// token minted minutes before rather than the expired original. Tokens are minted ahead of need, on the refresh
/// interval the other drivers' pools use, since the library asks for the password synchronously.
/// </summary>
internal sealed class RedisSignInPassword : DefaultOptionsProvider, IAsyncDisposable
{
    private readonly Func<CancellationToken, ValueTask<string>> _mint;
    private readonly TimeProvider _time;
    private readonly CancellationTokenSource _stop = new();
    private volatile string? _token;
    private Task _refreshing = Task.CompletedTask;

    internal RedisSignInPassword(Func<CancellationToken, ValueTask<string>> mint, TimeProvider? time = null)
    {
        _mint = mint;
        _time = time ?? TimeProvider.System;
    }

    public override string? Password => _token;

    /// <summary>Mints the first token, so a sign-in that fails does so at connect, then keeps the token fresh.</summary>
    public static async Task<RedisSignInPassword> StartAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var profile = request.Profile;
        var secret = request.Password;
        var signIn = new RedisSignInPassword(token => SignInTokens.GetAsync(profile, secret, token));
        await signIn.RefreshAsync(cancellationToken);
        signIn._refreshing = signIn.RefreshLoopAsync(signIn._stop.Token);
        return signIn;
    }

    internal async Task RefreshAsync(CancellationToken cancellationToken) => _token = await _mint(cancellationToken);

    private async Task RefreshLoopAsync(CancellationToken stop)
    {
        var wait = SignInTokenRefresh.Interval;
        while (true)
        {
            try
            {
                await Task.Delay(wait, _time, stop);
                await RefreshAsync(stop);
                wait = SignInTokenRefresh.Interval;
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException or TimeoutException or OperationCanceledException)
            {
                // The token in hand is good for a few minutes more; a blip in reaching AWS is tried again soon.
                wait = SignInTokenRefresh.RetryInterval;
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        await _refreshing;
        _stop.Dispose();
    }
}
