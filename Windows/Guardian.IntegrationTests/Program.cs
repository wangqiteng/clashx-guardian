using System.Net;
using System.Net.Http;
using System.Reflection;
using Guardian.Core;
using Guardian.Windows;
using Forms=System.Windows.Forms;
class AutomaticTest
{
 [STAThread] static int Main(string[] args)
 {
  if(args.Length==3 && args[0]=="--native-ui"){NativeUI.Run(args[1],args[2]);var r=System.Text.Json.JsonSerializer.Deserialize<NativeReply>(File.ReadAllText(args[2]))!;if(r.Error.Length==0&&!r.WindowMinimized)File.WriteAllText(args[2],System.Text.Json.JsonSerializer.Serialize(r with {Error="Window was restored"}));return 0;}
  if(!args.Contains("--run-live")){Console.WriteLine("Use --run-live only with Guardian stopped, iKuuu connected on its server page and minimized. This test changes nodes and restores its owned selection.");return 2;}
  Forms.Application.SetHighDpiMode(Forms.HighDpiMode.PerMonitorV2);Forms.Application.EnableVisualStyles();Forms.Application.SetCompatibleTextRenderingDefault(false);
  try{return Run();}catch(Exception ex){Console.WriteLine(ex);return 1;}
 }
 static int Run()
 {
  var native=new NativeController();var original=native.SnapshotAsync("",default).GetAwaiter().GetResult();Console.WriteLine("INITIAL: "+original.Selected);
  using var network=new NetworkProbe();network.RefreshRoute();
  var field=typeof(NetworkProbe).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;
  var transport=new FaultTransport((HttpClient)field.GetValue(network)!);field.SetValue(network,new HttpClient(transport){Timeout=TimeSpan.FromSeconds(6)});
  using var app=new TrayApp(network,()=>new Observed(native,transport),false);
  var type=typeof(TrayApp);type.GetField("nextUsage",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(app,TimeSpan.FromDays(365));
  using var timer=new Forms.Timer{Interval=500};bool finished=false;int outcome=1;
  var clock=System.Diagnostics.Stopwatch.StartNew();
  timer.Tick+=async(_,_)=>
  {
   if(finished)return;
   var message=(string)type.GetField("message",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(app)!;
   if(!message.StartsWith("已切换并验证")&&!(transport.Switches>0&&message.StartsWith("需要处理"))&&clock.Elapsed.TotalSeconds<160)return;
   finished=true;timer.Stop();
   try
   {
    await (Task)type.GetMethod("StopOperationAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(app,null)!;
    if(!message.StartsWith("已切换并验证"))throw new Exception("Automatic timer failed: "+message);
    var current=await native.SnapshotAsync("",default);
    if(current.Selected==original.Selected||transport.Switches==0||transport.FailedRequests<6||transport.RealRequests<3)throw new Exception("Automatic test did not exercise failure-to-switch-to-network verification");
    Console.WriteLine("PASS: unattended tray timer confirmed failure, benchmarked, switched and verified real network in "+(int)clock.Elapsed.TotalSeconds+"s");Console.WriteLine(message);
    if(current.Selected==transport.Owned)await native.SelectAsync("",original.Selected,default);
    var final=(await native.SnapshotAsync("",default)).Selected;
    Console.WriteLine("FINAL: "+final);
    if(final!=original.Selected)throw new Exception("Original node was not restored; a changed external selection was preserved");
    outcome=0;
   }
   catch(Exception ex){Console.WriteLine(ex);try{var s=await native.SnapshotAsync("",default);if(s.Selected==transport.Owned)await native.SelectAsync("",original.Selected,default);}catch(Exception cleanup){Console.WriteLine("Cleanup: "+cleanup.Message);}}
   finally{app.ExitThread();}
  };
  timer.Start();Forms.Application.Run(app);return outcome;
 }
 class Observed(IController inner,FaultTransport transport):IController
 {
  public Task<Snapshot> SnapshotAsync(string g,CancellationToken t)=>inner.SnapshotAsync(g,t);
  public Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names,CancellationToken t)=>inner.BenchmarkAsync(names,t);
  public async Task SelectAsync(string g,string name,CancellationToken t){await inner.SelectAsync(g,name,t);transport.Owned=name;transport.Switches++;transport.Fail=false;Console.WriteLine("SELECT CONFIRMED: "+name);}
 }
 class FaultTransport(HttpClient real):HttpMessageHandler
 {
  public bool Fail=true;public int FailedRequests,RealRequests,Switches;public string? Owned;
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken t)
  {
   if(Fail){Interlocked.Increment(ref FailedRequests);return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);}
   Interlocked.Increment(ref RealRequests);
   using var forwarded=new HttpRequestMessage(request.Method,request.RequestUri);
   foreach(var header in request.Headers)forwarded.Headers.TryAddWithoutValidation(header.Key,header.Value);
   return await real.SendAsync(forwarded,HttpCompletionOption.ResponseHeadersRead,t);
  }
  protected override void Dispose(bool disposing){if(disposing)real.Dispose();base.Dispose(disposing);}
 }
}
