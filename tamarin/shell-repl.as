import avmplus.*;
import flash.utils.ByteArray;

include "files.as"

com.las3r.runtime.RT.avmshellDomain = Domain.currentDomain;
var rt;
trace(rt = new com.las3r.runtime.RT);

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
	rt.evalStr(src, trace, trace, trace);
	var bytes = rt.compiler.getAOTCompileBytes();
	rt.compiler.endAOTCompile();
	return bytes;
}


// some player emulation from redtamarin

function getDefinitionByName(name:String):Object {
	return Domain.currentDomain.getClass(name) as Object;
}

function getQualifiedClassName(value:*):String {
    return avmplus.getQualifiedClassName( value );
}

// I don't think asc.jar likes embed tags...
var src = ByteArray.readFile("../src/lsr/las3r.core.lsr");
rt.evalStr(src);

// rt.evalStr("(trace 'foo)", complete, err);

//compileStr('"hello"', "test").writeFile("out.abc");
//compileStr(src, "las3r.core").writeFile("out.abc");

//compileStr("'hello", "las3r.core").writeFile("out.abc");

//trace(rt.evalStr('"hello"', complete, err));

var line;


while(true) {
	System.write("=> ");
	line = readLine();
	if(!line) break;
	var result:* = rt.evalStr(line);
	trace(rt.printString(result));
}