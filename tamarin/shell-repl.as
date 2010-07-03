import avmplus.*;
import flash.utils.ByteArray;

include "files.as"

com.las3r.runtime.RT.avmshellDomain = Domain.currentDomain;
var rt;
trace(rt = new com.las3r.runtime.RT);

// I don't think asc.jar likes embed tags...
var src = ByteArray.readFile("../src/lsr/las3r.core.lsr")
src = src.toString();

function complete(x:*) {
  trace("complete: " + x);
}

function err(x:*) {
  trace("error: " + x);
}

// (defn compile-str
//   "Evaluate all forms in src, returns a ByteArray containing compiled swf."
//   [src module-id callback]
//   (. *compiler* (beginAOTCompile module-id))
//   (eval src
// 	(fn [val] 
// 	  (callback (. *compiler* (getAOTCompileBytes)))
// 	  (. *compiler* (endAOTCompile)))
// 	(fn [err]
// 	  (binding [*out* *err*] (prn err))
// 	  (. *compiler* (endAOTCompile)))
// 	(fn [] (print "."))
// 	))

function compileStr(src:String, id:String):ByteArray {
	rt.compiler.beginAOTCompile(id);
	rt.evalStr(src);
	var bytes = rt.compiler.getAOTCompileBytes();
	rt.compiler.endAOTCompile();
	return bytes;
}

// rt.evalStr(src, complete, err);
// rt.evalStr("(trace 'foo)", complete, err);

compileStr('"hello"', "test").writeFile("out.abc");

for(x in RT.modules) {
	var constr = RT.modules[x];
	trace("modules[" + x + "] == " + constr);
	if(constr is Function) {
		trace(constr(trace,trace,trace));
	}
}

//trace(rt.evalStr('"hello"', complete, err));
