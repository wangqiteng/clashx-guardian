using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Windows.Forms;
class Probe {
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [STAThread] static void Main(string[] args){if(!args.Contains("--run-ui")){Console.WriteLine("Use --run-ui to run the brief owned-window menu layout and dismissal tests.");Environment.ExitCode=2;return;}Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);Application.EnableVisualStyles();
 var assembly=Assembly.Load("IKuuuGuardian");var type=assembly.GetType("Guardian.Windows.TrayApp")!;var owner=RuntimeHelpers.GetUninitializedObject(type);
 var heading=new ToolStripMenuItem{Enabled=false};var rows=Enumerable.Range(0,4).Select(_=>new ToolStripMenuItem{Enabled=false}).ToArray();
 type.GetField("usageItem",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(owner,heading);type.GetField("usageDetails",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(owner,rows);
 type.GetMethod("RenderUsage",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(owner,new object[]{"读取账号：测试账号\n5 小时：剩余 80%（已用 20%）\n7 天：剩余 90%（已用 10%）"});
 using var menu=(ContextMenuStrip)Activator.CreateInstance(assembly.GetType("Guardian.Windows.TrayMenu")!,true)!;menu.Items.Add("探针可达 · 自动切换已启用");menu.Items.Add(heading);menu.Items.AddRange(rows);menu.Items.Add("查看详细状态");menu.Items.Add("暂停检测");menu.PerformLayout();menu.Size=menu.GetPreferredSize(System.Drawing.Size.Empty);
 var heights=menu.Items.Cast<ToolStripItem>().Where(x=>x.Available).Select(x=>x.Height).ToArray();Console.WriteLine("Rows: "+string.Join(",",heights));
 if(heading.Text.Contains('\n')||rows.Any(r=>r.Text.Contains('\n'))||heights.Any(h=>h>24))throw new Exception("Quota inflated normal menu row height");
 using(var bmp=new System.Drawing.Bitmap(menu.Width,menu.Height)){menu.DrawToBitmap(bmp,new System.Drawing.Rectangle(System.Drawing.Point.Empty,menu.Size));bmp.Save(Path.Combine(Path.GetTempPath(),"IKuuuGuardian-compact-menu-preview.png"));}Console.WriteLine("PASS: production quota renderer keeps independent compact rows");
 menu.Opened+=(_,_)=>Console.WriteLine("OPEN visible="+menu.Visible+" focused="+menu.Focused+" fg="+GetForegroundWindow()+" popup="+menu.Handle); menu.GotFocus+=(_,_)=>Console.WriteLine("GOT focused="+menu.Focused);menu.LostFocus+=(_,_)=>Console.WriteLine("LOST focused="+menu.Focused+" contains="+menu.ContainsFocus+" fg="+GetForegroundWindow());menu.Closed+=(_,e)=>Console.WriteLine("CLOSED reason="+e.CloseReason);
 using var form=new Form{Text="Guardian 菜单关闭验收",ShowInTaskbar=false,StartPosition=FormStartPosition.Manual,Location=new System.Drawing.Point(60,60),Size=new System.Drawing.Size(240,100)};
 using var tick=new System.Windows.Forms.Timer{Interval=350};int phase=0;Exception failure=null;
 tick.Tick+=(_,_)=>{try{switch(phase++){
 case 0: menu.Show(form,new System.Drawing.Point(10,30));break;
 case 1: if(!menu.Visible||!menu.ContainsFocus)throw new Exception("Popup did not receive focus"); form.Activate();break;
 case 2: if(menu.Visible)throw new Exception("Popup remained open after foreground moved to another window"); Console.WriteLine("PASS: visible popup activation and focus-loss dismissal");menu.Show(form,new System.Drawing.Point(10,30));break;
 case 3: typeof(ToolStripDropDown).GetMethod("ProcessDialogKey",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(menu,new object[]{Keys.Escape});break;
 case 4: if(menu.Visible)throw new Exception("Escape did not close popup"); Console.WriteLine("PASS: Escape closes popup");tick.Stop();form.Close();break;
 }}catch(Exception ex){failure=ex;tick.Stop();menu.Close();form.Close();}};
 form.Shown+=(_,_)=>tick.Start();Application.Run(form);if(failure!=null)throw failure;
 }}
