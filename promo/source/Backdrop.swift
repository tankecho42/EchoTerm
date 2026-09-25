import AppKit
import SwiftUI
struct Backdrop: View {
 var body: some View {
  ZStack {
   LinearGradient(colors:[Color(red:0.04,green:0.08,blue:0.18),Color(red:0.20,green:0.38,blue:0.59),Color(red:0.09,green:0.15,blue:0.28)],startPoint:.topLeading,endPoint:.bottomTrailing)
   Ellipse().fill(Color(red:0.28,green:0.63,blue:0.97).opacity(0.6)).frame(width:1000,height:650).blur(radius:100).offset(x:-380,y:-230)
   Ellipse().fill(Color(red:0.88,green:0.56,blue:0.35).opacity(0.55)).frame(width:700,height:450).blur(radius:110).offset(x:540,y:300)
   HStack(spacing:28) {
    VStack(alignment:.leading,spacing:22) {
     HStack { Circle().fill(.red.opacity(0.5)).frame(width:9,height:9);Circle().fill(.yellow.opacity(0.5)).frame(width:9,height:9);Circle().fill(.green.opacity(0.5)).frame(width:9,height:9);Spacer();Text("AURORA / WORKSPACE").font(.system(size:10,weight:.medium,design:.monospaced)) }
     HStack(alignment:.top,spacing:30) {
      VStack(alignment:.leading,spacing:20){Text("EXPLORER").font(.system(size:10));Text("▾  aurora\n\n    config\n\n    server.py\n\n    tests\n\n    README.md").font(.system(size:13,design:.monospaced))}.foregroundColor(.white.opacity(0.4))
      VStack(alignment:.leading,spacing:18){Text("server.py").font(.system(size:13));Text("from aurora import App\n\napp = App()\n\n@app.route(\"/health\")\ndef health():\n    return {\n        \"status\": \"ready\",\n        \"version\": \"1.0.0\"\n    }\n\napp.listen(port=4317)").font(.system(size:16,design:.monospaced)).foregroundColor(Color(red:0.65,green:0.79,blue:0.95))}
     };Spacer()
    }.padding(24).frame(width:690,height:650).background(Color(red:0.06,green:0.10,blue:0.17).opacity(0.80)).clipShape(RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).stroke(.white.opacity(0.10))).offset(x:-65,y:-95)
    VStack(alignment:.leading,spacing:25){HStack{Text("Aurora").font(.system(size:17,weight:.semibold));Spacer();Image(systemName:"square.grid.2x2")};Divider();ForEach(["Project overview","Design notes","Release checklist","API documentation"],id:\.self){s in HStack{Image(systemName:"doc.text").foregroundColor(.blue);Text(s).font(.system(size:14));Spacer()}.padding(15).background(.white.opacity(0.035)).cornerRadius(8)};Spacer();Text("LOCAL WORKSPACE").font(.system(size:10,design:.monospaced)).foregroundColor(.white.opacity(0.35))}.padding(28).frame(width:405,height:560).background(Color(red:0.12,green:0.17,blue:0.24).opacity(0.85)).cornerRadius(16).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.12))).offset(x:0,y:120)
   }.foregroundColor(.white.opacity(0.8))
  }.ignoresSafeArea()
 }
}
final class Delegate:NSObject,NSApplicationDelegate {
 var window:NSWindow!
 func applicationDidFinishLaunching(_ note:Notification){
  let frame=NSScreen.main!.frame
  window=NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
  window.contentView=NSHostingView(rootView:Backdrop());window.title="EchoTerm Film Backdrop"
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
 }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
let app=NSApplication.shared;let delegate=Delegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
