using System.Globalization;
using System.Net;
using System.Net.Sockets;

// Stands in for ssh.exe in the tunnel tests: it reads the -L forward the factory built and listens on its local end,
// the way ssh does once a login succeeds. The user name picks a failure to act out.

var forward = Value("-L");
var user = Value("-l");

if (user == "denied")
{
    await Console.Error.WriteLineAsync("nobody@127.0.0.1: Permission denied (publickey,password).");
    return 255;
}

if (forward is null)
{
    await Console.Error.WriteLineAsync("no -L forward given");
    return 2;
}

if (user == "hang")
{
    await Task.Delay(Timeout.Infinite);
}

var port = int.Parse(forward.Split(':')[1], CultureInfo.InvariantCulture);

// A real ssh binds the forward only after authentication, which takes a moment.
await Task.Delay(300);
using var listener = new TcpListener(IPAddress.Loopback, port);
listener.Start();
while (true)
{
    using var client = await listener.AcceptTcpClientAsync();
}

string? Value(string flag)
{
    var index = Array.IndexOf(args, flag);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
}
