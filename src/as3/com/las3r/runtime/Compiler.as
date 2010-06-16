/**
*   Copyright (c) Rich Hickey. All rights reserved.
*   Copyright (c) Aemon Cannon. All rights reserved.
*   The use and distribution terms for this software are covered by the
*   Common Public License 1.0 (http://opensource.org/licenses/cpl.php)
*   which can be found in the file CPL.TXT at the root of this distribution.
*   By using this software in any fashion, you are agreeing to be bound by
* 	 the terms of this license.
*   You must not remove this notice, or any other, from this software.
**/

package com.las3r.runtime{
	import com.las3r.util.*;
	import com.las3r.jdk.io.PushbackReader;
	import com.las3r.errors.LispError;
	import com.las3r.errors.CompilerError;
	import com.las3r.gen.*;
	import flash.utils.getQualifiedClassName;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.events.*;
	import com.hurlant.eval.gen.Script;
	import com.hurlant.eval.gen.ABCEmitter;
	import com.hurlant.eval.gen.AVM2Assembler;
	import com.hurlant.eval.abc.*;
	import com.hurlant.eval.ByteLoader;
	import com.hurlant.eval.dump.ABCDump;

	public class Compiler{

		public static var MAX_POSITIONAL_ARITY:int = 20;

		private var _rt:RT;
		public var specialParsers:IMap;

		public var LINE:Var;
		public var SOURCE:Var;
		public var CURRENT_METHOD:Var;
		public var BINDING_SET_STACK:Var;
		public var RECURING_BINDER:Var;
		public var RECUR_ARGS:Var;
		public var RECUR_LABEL:Var;
		public var IN_CATCH_FINALLY:Var;
		public var CURRENT_MODULE_SWF:Var;
		public var FN_CONSTANTS:Var;

		public function get rt():RT{ return _rt; }

		public function Compiler(rt:RT){
			_rt = rt;

			specialParsers = RT.map(
				_rt.DEF, DefExpr.parse,
				_rt.RECUR, RecurExpr.parse,
				_rt.IF, IfExpr.parse,
				_rt.LET, LetExpr.parse,
				_rt.DO, BodyExpr.parse,
				_rt.QUOTE, ConstantExpr.parse,
				_rt.THE_VAR, TheVarExpr.parse,
				_rt.DOT, HostExpr.parse,
				_rt.ASSIGN, AssignExpr.parse,
				_rt.TRY, TryExpr.parse,
				_rt.THROW, ThrowExpr.parse,
				_rt.NEW, NewExpr.parse
			);

			SOURCE = new Var(_rt, null, null, "Evaluated Source");
			LINE = new Var(_rt, null, null, 0);
			BINDING_SET_STACK = new Var(_rt, null, null, RT.vector());
			CURRENT_METHOD = new Var(_rt, null, null, null);
			RECURING_BINDER = new Var(_rt, null, null, null);
			RECUR_ARGS = new Var(_rt, null, null, null);
			RECUR_LABEL = new Var(_rt, null, null, null);
			IN_CATCH_FINALLY = new Var(_rt, null, null, false);
			FN_CONSTANTS = new Var(_rt, null, null, null);
			CURRENT_MODULE_SWF = new Var(_rt, null, null, null);
		}

		public function interpret(form:Object):Object{
			Var.pushBindings(rt, RT.map(
					rt.CURRENT_NS, rt.CURRENT_NS.get()
				));
			var expr:Expr = analyze(C.EXPRESSION, form);
			var ret:Object = expr.interpret();
			Var.popBindings(rt);
			return ret;
		}


		/**
		* Don't call this directly. Use interface in RT.
		* 
		* @param rdr 
		* @param _onComplete 
		* @param _onFailure 
		* @param _progress 
		* @param sourcePath 
		* @param sourceName 
		* @return
		*/
		public function load(rdr:PushbackReader, _onComplete:Function = null, _onFailure:Function = null, _progress:Function = null, sourcePath:String = null, sourceName:String = null):void{
			var onComplete:Function = _onComplete || function(val:*):void{};
			var onFailure:Function = _onFailure || function(error:*):void{};
			var progress:Function = _progress || function():void{};

			var EOF:Object = new Object();

			var loadAllForms:Function = function(result:*):void{
				try{
					var form:Object = rt.lispReader.read(rdr, false, EOF);
				}
				catch(e:LispError){
					onFailure(e);
					return;
				}
				if(form != EOF){
					progress();
					try{
						loadForm(form, loadAllForms, onFailure);
					}
					catch(e:LispError){
						// Suppress exceptions. We can't handle them for async code anyhow. Just pass back to the toplevel.
						onFailure(e);
					}
				}
				else{
					onComplete(result);
				}
			}

			loadAllForms(null);
		}

		protected function loadForm(form:Object, callback:Function, errorCallback:Function):void{
			var moduleId:String = GUID.create();
			var current:SWFGen = new SWFGen(rt, moduleId);
			trace("loadForm - moduleId: " + moduleId);
			try{
				Var.pushBindings(rt,
					RT.map(
						CURRENT_MODULE_SWF, current
					)
				);
				var expr:Expr = analyze(C.EXPRESSION, form);
			}
			finally{
				Var.popBindings(rt);
			}

			var aot:SWFGen = SWFGen(rt.AOT_MODULE_SWF.get());
			if(aot != null){ aot.addExpr(expr); }
			trace("aot: " + aot);
			current.addExpr(expr);

			var swfBytes:ByteArray = current.emit();
			ByteLoader.loadBytes(swfBytes, function():void{
					var moduleConstructor:Function = RT.modules[moduleId];
					if(!(moduleConstructor is Function)) {
						throw new Error("IllegalStateException: no module constructor at " + moduleId);
					}
					moduleConstructor(rt, callback, errorCallback);
				}, 
				true
			);
		}

		public function beginAOTCompile(moduleId:String):void{
			rt.AOT_MODULE_SWF.set(new SWFGen(rt, moduleId));
		}

		public function endAOTCompile():void{
			rt.AOT_MODULE_SWF.set(null);
		}

		public function getAOTCompileBytes():ByteArray{
			var swf:SWFGen = SWFGen(rt.AOT_MODULE_SWF.get());
			return swf.emit();
		}

		public function currentNS():LispNamespace{
			return rt.currentNS();
		}

		public function isSpecial(sym:Object):Boolean{
			return rt.isSpecial(sym);
		}

		public function lookupVar(sym:Symbol, internNew:Boolean):Var {
			var v:Var = null;

			//note - ns-qualified vars in other namespaces must already exist
			if(sym.ns != null)
			{
				var nsSym:Symbol = Symbol.intern1(rt, sym.ns);
				var ns:LispNamespace = LispNamespace.find(rt, nsSym);
				if(ns == null) return null;
				//throw new Exception("No such namespace: " + sym.ns);
				var name:Symbol = Symbol.intern1(rt, sym.name);
				if(internNew && ns == currentNS()){
					v = currentNS().intern(name);
				}
				else{
					v = ns.findInternedVar(name);
				}
			}
			else
			{
				//is it mapped?
				var o:Object = currentNS().getMapping(sym);
				if(o == null)
				{
					//introduce a new var in the current ns
					if(internNew){
						v = currentNS().intern(Symbol.intern1(rt, sym.name));
					}
				}
				else if(o is Var)
				{
					v = Var(o);
				}
				else
				{
					throw new Error("Expecting var, but " + sym + " is mapped to " + o);
				}
			}
			return v;
		}

		public function registerLocal(num:int, sym:Symbol, init:Expr = null, _lbs:LocalBindingSet = null):LocalBinding{
			var lbs:LocalBindingSet = _lbs || currentLocalBindingSet()
			if(!lbs) throw new Error("IllegalStateException: cannot register local without LocalBindingSet.")
			return lbs.registerLocal(num, sym, init);
		}

		
		public function registerConstant(o:Object):void{
			if(!CURRENT_MODULE_SWF.isBound())
			throw new Error("IllegalStateException: CURRENT_MODULE_SWF is unbound during compilation.");

			var swf:SWFGen = SWFGen(CURRENT_MODULE_SWF.get());
			swf.addConst(o);

			var aot:SWFGen = SWFGen(rt.AOT_MODULE_SWF.get());
			if(aot) aot.addConst(o);

			if(FN_CONSTANTS.isBound()){
				var fnConsts:ISet = ISet(FN_CONSTANTS.get());
				FN_CONSTANTS.set(fnConsts.add(o));
			}
			
		}


		public function analyze(context:C, form:Object, name:String = null):Expr{
			// TODO Re-add line-number tracking here (requires metadata).
			var line:int = int(LINE.get());
			if(RT.meta(form) != null && RT.meta(form).containsKey(_rt.LINE_KEY)){
				line = int(RT.meta(form).valAt(_rt.LINE_KEY));
			}
			Var.pushBindings(_rt, RT.map(LINE, line));
			try{
				trace( "analyzing: " + form + " - " + _rt.printString(form) );
				//todo symbol macro expansion?
				if(form === null)
				return NilExpr.instance;

				else if(form === RT.T)
				return BooleanExpr.true_instance;

				else if(form === RT.F)
				return BooleanExpr.false_instance;

				else if(form is Symbol)
				return analyzeSymbol(Symbol(form));

				else if(form is Keyword)
				return new KeywordExpr(this, Keyword(form));

				else if(form is Number)
				return new NumExpr(Number(form));

				else if(form is String)
				return new StringExpr(this, StringUtil.intern(rt, String(form)));

 				else if(form is ISeq)
 				return analyzeSeq(context, ISeq(form), name);

				else if(form is IVector)
				return VectorExpr.parse(this, context, IVector(form));

				else if(form is IMap)
				return MapExpr.parse(this, context, IMap(form));

				else if(form is RegExp) {
					var re:RegExp = RegExp(form);
					return NewExpr.parse(this, context, RT.list(null, RegExp, re.source, RegExpUtil.flags(re)));
				}

				else
				return new ConstantExpr(this, form);



			}
			catch(e:*) 
			{
				var msg:String = "CompilerError at " + SOURCE.get() + ":" + int(LINE.get()) + ":  " + (e is Error ? Error(e).message : String(e));
				throw new CompilerError(msg);
			}
			finally
			{
				Var.popBindings(_rt);
			}

			return null;
		}


		private function analyzeSymbol(sym:Symbol):Expr{

			if(sym.ns == null) //ns-qualified syms are always Vars
			{
				var b:LocalBinding = referenceLocal(sym);
				if(b != null){
					return new LocalBindingExpr(b);
				}
			}

			var o:Object = resolve(sym);
			if(o is Var)
			{
				var v:Var = Var(o);
				return new VarExpr(this, v);
			}
			else if(o is Class){
				return new ConstantExpr(this, o);
			}
			else{
				throw new Error("Unable to resolve symbol: " + sym + " in this context");
			}
		}

		public function resolve(sym:Symbol):Object{
			return _rt.resolve(sym);
		}

		public function resolveIn(n:LispNamespace, sym:Symbol):Object{
			return _rt.resolveIn(n, sym);
		}

		private function analyzeSeq(context:C, form:ISeq , name:String ):Expr {
			trace("analyzeSeq: " + _rt.printString(form));
			var me:Object = macroexpand1(form);
			if(me != form)
			return analyze(context, me, name);
			
			var op:Object = RT.first(form);
			if(Util.equal(_rt.FN, op)){
				return FnExpr.parse(this, context, form);
			}
			else if(specialParsers.valAt(op) != null){
				trace("special: " + specialParsers.valAt(op));
				var parse:Function = specialParsers.valAt(op) as Function;
				return parse(this, context, form);
			}
			else{
				return InvokeExpr.parse(this, context, form);
			}
			return null;
		}

		public function macroexpand1(x:Object):Object{
			if(x is ISeq)
			{
				var form:ISeq = ISeq(x);
				var op:Object = RT.first(form);
				if(isSpecial(op))
				return x;
				//macro expansion
				var v:Var = isMacro(op);
				if(v != null)
				{
					return v.applyTo(form.rest());
				}
			}
			return x;
		}


		public function isMacro(op:Object):Var{
			//no local macros for now
			if(op is Symbol && referenceLocal(Symbol(op)) != null)
			return null;
			if(op is Symbol || op is Var)
			{
				var v:Var  = (op is Var) ? Var(op) : lookupVar(Symbol(op), false);
				if(v != null && v.isMacro())
				{
					if(v.ns != currentNS() && !v.isPublic())
					throw new Error("IllegalStateException: var: " + v + " is not public");
					return v;
				}
			}
			return null;
		}


		public function referenceLocal(sym:Symbol):LocalBinding{
			var bindingSetStack:IVector = IVector(BINDING_SET_STACK.get());
			var len:int = bindingSetStack.count();
			for(var i:int = len - 1; i >= 0; i--){
				var lbs:LocalBindingSet = LocalBindingSet(bindingSetStack.nth(i));
				var b:LocalBinding = LocalBinding(lbs.bindingFor(sym));
				if(b){
					return b;
				}
			}
			return null;
		}

		public function pushLocalBindingSet(set:LocalBindingSet):void{
			var prevStack:IVector = IVector(BINDING_SET_STACK.get());
			var newStack:IVector = prevStack.cons(set);
			Var.pushBindings(rt, RT.map(BINDING_SET_STACK, newStack));
		}

		public function popLocalBindingSet():void{
			Var.popBindings(rt);
		}

		public function currentLocalBindingSet():LocalBindingSet{
			return LocalBindingSet(IVector(BINDING_SET_STACK.get()).peek());
		}


	}
}


import com.las3r.runtime.*;
import com.las3r.util.*;
import com.las3r.gen.*;
import com.hurlant.eval.gen.Script;
import com.hurlant.eval.gen.Method;
import com.hurlant.eval.gen.ABCEmitter;
import com.hurlant.eval.gen.AVM2Assembler;
import com.hurlant.eval.abc.ABCSlotTrait;
import com.hurlant.eval.abc.ABCException;
import org.pranaframework.reflection.Type;
import org.pranaframework.reflection.Field;


interface AssignableExpr{

	function interpretAssign(val:Expr):Object;

	function emitAssign(context:C, gen:CodeGen, val:Expr):void;

}


class LiteralExpr implements Expr{

	public function val():Object{ return null }

	public function interpret():Object{
		return val();
	}

	public function emit(context:C, gen:CodeGen):void{}

}




class UntypedExpr implements Expr{

	public function interpret():Object{ throw "SubclassResponsibility";}

	public function emit(context:C, gen:CodeGen):void{ throw "SubclassResponsibility";}

}



class BooleanExpr extends LiteralExpr{
	public static var true_instance:BooleanExpr = new BooleanExpr(true);
	public static var false_instance:BooleanExpr = new BooleanExpr(false);	
	private var _val:Boolean;

	public function BooleanExpr(val:Boolean){
		_val = val;
	}

	override public function val():Object{
		return _val ? RT.T : RT.F;
	}

	override public function emit(context:C, gen:CodeGen):void{
		if(_val){
			gen.asm.I_pushtrue();
		}
		else{
			gen.asm.I_pushfalse();
		}
		if(context == C.STATEMENT){ gen.asm.I_pop();}
	}

}




class StringExpr extends LiteralExpr{
	public var str:String;
	private var _compiler:Compiler;

	public function StringExpr(c:Compiler, str:String){
		this.str = str;
		_compiler = c;
	}

	override public function val():Object{
		return str;
	}

	override public function emit(context:C, gen:CodeGen):void{
		if(context != C.STATEMENT){ gen.asm.I_pushstring( gen.emitter.constants.stringUtf8(str) ); }
	}

}




class NumExpr extends LiteralExpr{
	public var num:Number;

	public function NumExpr(num:Number){
		this.num = num;
	}

	override public function val():Object{
		return this.num;
	}

	override public function emit(context:C, gen:CodeGen):void{
		if(context != C.STATEMENT){ 
			if(this.num is uint){
				gen.asm.I_pushuint(gen.emitter.constants.uint32(this.num));
			}
			else if(this.num is int){
				gen.asm.I_pushint(gen.emitter.constants.int32(this.num));
			}
			else {
				gen.asm.I_pushdouble(gen.emitter.constants.float64(this.num));
			}
		}
	}

}




class ConstantExpr extends LiteralExpr{
	public var v:Object;
	private var _compiler:Compiler;

	public function ConstantExpr(c:Compiler, v:Object){
		this.v = v;
		_compiler = c;
		_compiler.registerConstant(v);
	}

	override public function val():Object{
		return v;
	}

	override public function emit(context:C, gen:CodeGen):void{
		gen.emitConstant(this.v);
		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}

	public static function parse(c:Compiler, context:C, form:Object):Expr{
		var v:Object = RT.second(form);
		if(v == null){
			return NilExpr.instance;
		}
		else{
			return new ConstantExpr(c, v);
		}

	}
}

class NilExpr extends LiteralExpr{

	public static var instance:NilExpr = new NilExpr();

	override public function val():Object{
		return null;
	}

	override public function emit(context:C, gen:CodeGen):void{
		gen.asm.I_pushnull();
		if(context == C.STATEMENT){ gen.asm.I_pop();}
	}

}



class KeywordExpr implements Expr{
	public var k:Keyword;
	private var _compiler:Compiler;

	public function KeywordExpr(compiler:Compiler, k:Keyword){
		_compiler = compiler;
		this.k = k;
		compiler.registerConstant(k);
	}

	public function interpret():Object {
		return k;
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.emitConstant(this.k);
		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}
}



class VarExpr implements Expr, AssignableExpr{
	public var aVar:Var;
	private var _compiler:Compiler;

	public function VarExpr(c:Compiler, v:Var){
		this.aVar = v;
		_compiler = c;
		c.registerConstant(v);
	}

	public function interpret():Object{
		return aVar.get();
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.emitConstant(this.aVar);
		gen.getVar();
		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}

	public function interpretAssign(val:Expr):Object{
		return aVar.set(val.interpret());
	}

	public function emitAssign(context:C, gen:CodeGen, val:Expr):void{
		gen.emitConstant(this.aVar);
		val.emit(C.EXPRESSION, gen);
		gen.setVar();
		if(context == C.STATEMENT) { gen.asm.I_pop(); }
	}
}

class TheVarExpr implements Expr{
	public var aVar:Var;
	private var _compiler:Compiler;

	public function TheVarExpr(c:Compiler, v:Var){
		this.aVar = v;
		_compiler = c;
		c.registerConstant(v);
	}

	public function interpret():Object{
		return aVar;
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.emitConstant(this.aVar);
		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}

	public static function parse(c:Compiler, context:C, form:Object):Expr{
		var sym:Symbol = Symbol(RT.second(form));
		var v:Var = c.lookupVar(sym, false);

		if(v == null)
		throw new Error("Unable to resolve var: " + sym + " in this context");

		return new TheVarExpr(c, v);
	}

}


class IfExpr implements Expr{
	public var testExpr:Expr;
	public var thenExpr:Expr;
	public var elseExpr:Expr;
	private var _compiler:Compiler;

	public function IfExpr(c:Compiler, testExpr:Expr, thenExpr:Expr, elseExpr:Expr ){
		_compiler = c;
		this.testExpr = testExpr;
		this.thenExpr = thenExpr;
		this.elseExpr = elseExpr;
	}

	public function interpret():Object{
		var t:Object = testExpr.interpret();
		if(t != null && t != RT.F){
			return thenExpr.interpret();
		}
		else{
			return elseExpr.interpret();
		}
	}

	public function emit(context:C, gen:CodeGen):void{
		testExpr.emit(C.EXPRESSION, gen);

		/* NOTE: newLabel() will remember the stack depth at the location
		where it is called. So call it when you know the stack depth
		will be the same as that at the corresponding called to I_label()
		*/

		var nullLabel:Object = gen.asm.newLabel();
		var falseLabel:Object = gen.asm.newLabel();
		gen.asm.I_dup();
		gen.asm.I_pushnull();
		gen.asm.I_ifeq(nullLabel); /* This'll net null and undefined.. */
		gen.asm.I_pushfalse();
		gen.asm.I_ifstricteq(falseLabel);/* And this will get the falses. */

		/* TODO: Is it necessary to coerce_a the return values of the then and else?
		Getting a verification error without the coersion, if return types are different.
		*/

		thenExpr.emit(C.EXPRESSION, gen);
		if(context == C.STATEMENT){ 
			gen.asm.I_pop(); 
		}
		else{
			gen.asm.I_coerce_a();
		}
		var endLabel:Object = gen.asm.newLabel();
		gen.asm.I_jump(endLabel);
		gen.asm.I_label(nullLabel);
		gen.asm.I_pop();
		gen.asm.I_label(falseLabel);
		elseExpr.emit(C.EXPRESSION, gen);
		if(context == C.STATEMENT){ 
			gen.asm.I_pop(); 
		}
		else{
			gen.asm.I_coerce_a();
		}
		gen.asm.I_label(endLabel);
	}

	public static function parse(c:Compiler, context:C, frm:Object):Expr{
		var form:ISeq = ISeq(frm);
		//(if test then) or (if test then else)
		if(form.count() > 4)
		throw new Error("Too many arguments to if");
		else if(form.count() < 3)
		throw new Error("Too few arguments to if");
		return new IfExpr(
			c,
			c.analyze(context == C.INTERPRET ? context : C.EXPRESSION, RT.second(form)),
			c.analyze(context, RT.third(form)),
			c.analyze(context, RT.fourth(form)) // Will result in NilExpr if fourth form is missing.
		);
	}
}



class BodyExpr implements Expr{
	public var exprs:IVector;
	private var _compiler:Compiler;

	public function BodyExpr(c:Compiler, exprs:IVector){
		this.exprs = exprs;
		_compiler = c;
	}

	public static function parse(c:Compiler, context:C, frms:Object):Expr{
		var forms:ISeq = ISeq(frms);
		if(Util.equal(RT.first(forms), c.rt.DO)){
			forms = RT.rest(forms);
		}
		var exprs:IVector = RT.vector();
		for(; forms != null; forms = forms.rest())
		{
			if(context != C.INTERPRET && (context == C.STATEMENT || forms.rest() != null)){
				exprs = exprs.cons(c.analyze(C.STATEMENT, forms.first()));
			}
			else{
				exprs = exprs.cons(c.analyze(context, forms.first()));
			}
		}
		if(exprs.count() == 0){
			exprs = exprs.cons(NilExpr.instance);
		}
		return new BodyExpr(c, exprs);
	}

	public function interpret():Object{
		var ret:Object = null;
		exprs.each(function(e:Expr):void{
				ret = e.interpret();
			});
		return ret;
	}

	public function emit(context:C, gen:CodeGen):void{
		var len:int = exprs.count();
		for(var i:int = 0; i < len - 1; i++)
		{
			var e:Expr = Expr(exprs.nth(i));
			e.emit(C.STATEMENT, gen);
		}
		var last:Expr = Expr(exprs.nth(len - 1));
		last.emit(context, gen);
	}

}



class DefExpr implements Expr{
	public var aVar:Var;
	public var init:Expr;
	public var initProvided:Boolean;
	public var meta:Expr;
	private var _compiler:Compiler;

	public function DefExpr(compiler:Compiler, inVar:Var, init:Expr, meta:Expr, initProvided:Boolean){
		aVar = inVar;
		this.init = init;
		this.initProvided = initProvided;
		this.meta = meta;
		_compiler = compiler;
		compiler.registerConstant(inVar);
	}

	public function interpret():Object{
		if(initProvided){
			aVar.bindRoot(init.interpret());
		}
		return aVar;
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.emitConstant(this.aVar);
		if(initProvided)
		{
			gen.asm.I_dup();
			init.emit(C.EXPRESSION, gen);
			gen.bindVarRoot();
		}
		if(meta != null)
		{
			gen.asm.I_dup();
			meta.emit(C.EXPRESSION, gen);
			gen.setMeta();
		}
		if(context == C.STATEMENT){gen.asm.I_pop();}
	}


	public static function parse(compiler:Compiler, context:C, form:Object):Expr{
		//(def x) or (def x initexpr)
		if(RT.count(form) > 3)
		throw new Error("Too many arguments to def");
		else if(RT.count(form) < 2)
		throw new Error("Too few arguments to def");
		else if(!(RT.second(form) is Symbol))
		throw new Error("Second argument to def must be a Symbol");
		var sym:Symbol = Symbol(RT.second(form));

		var v:Var = compiler.lookupVar(sym, true);
		if(v == null){
			throw new Error("Can't refer to qualified var that doesn't exist");
		}

		if(!v.ns.equals(compiler.currentNS())){
			if(sym.ns == null){
				throw new Error("Name conflict, can't def " + sym + " because namespace: " + compiler.currentNS().name + " refers to:" + v);
			}
			else{
				throw new Error("Can't create defs outside of current ns");
			}
		}

		var mm:IMap = sym.meta || RT.map();
		// TODO: Aemon add line info here..
		// mm = IMap(RT.assoc(mm, RT.LINE_KEY, LINE.get()).assoc(RT.FILE_KEY, SOURCE.get()));
		var meta:Expr = compiler.analyze(context == C.INTERPRET ? context : C.EXPRESSION, mm);
		return new DefExpr(compiler, v, compiler.analyze(context == C.INTERPRET ? context : C.EXPRESSION, RT.third(form), v.sym.name), meta, RT.count(form) == 3);
	}

}


class FnMethod{
	public var nameLb:LocalBinding;
	public var params:IVector;
	public var reqParams:IVector;
	public var restParam:LocalBinding;
	public var body:BodyExpr;
	public var paramBindings:LocalBindingSet;
	public var startLabel:Object
	public var surroundingFn:FnMethod;
	public var hasNestedFn:Boolean = false;
	private var _compiler:Compiler;
	private var _func:FnExpr;

	public function FnMethod(c:Compiler, f:FnExpr){
		_compiler = c;
		_func = f;
	}

	public static function parse(c:Compiler, context:C, form:ISeq, f:FnExpr):FnMethod{
		var meth:FnMethod = new FnMethod(c, f);

		if(c.CURRENT_METHOD.isBound()){
			meth.surroundingFn = FnMethod(c.CURRENT_METHOD.get());
			meth.surroundingFn.hasNestedFn = true;
		}

		meth.params = IVector(RT.first(form));
		if(meth.params.count() > Compiler.MAX_POSITIONAL_ARITY){
			throw new Error("Can't specify more than " + Compiler.MAX_POSITIONAL_ARITY + " params");
		}
		meth.reqParams = RT.vector();
		meth.paramBindings = new LocalBindingSet();

		var state:PSTATE = PSTATE.REQ;
		for(var i:int = 0; i < meth.params.count(); i++)
		{
			var param:Object = meth.params.nth(i);
			var paramSym:Symbol;
			if(param is List) {
				paramSym = Symbol(param.first());
			}
			else if(param is Symbol){
				paramSym = Symbol(param);
			}
			else{			
				throw new Error("IllegalArgumentException: fn params must be Symbols or (Symbol val) pair.");
			}
			if(paramSym.getNamespace() != null)
			throw new Error("Can't use qualified name as parameter: " + paramSym);
			if(param.equals(c.rt._AMP_))
			{
				if(state == PSTATE.REQ)
				state = PSTATE.REST;
				else
				throw new Error("Exception: Invalid parameter list.");
			}
			else
			{
				switch(state)
				{
					case PSTATE.REQ:
					meth.reqParams = meth.reqParams.cons(meth.paramBindings.registerLocal(c.rt.nextID(), paramSym));
					break;

					case PSTATE.REST:
					meth.restParam = meth.paramBindings.registerLocal(c.rt.nextID(), paramSym);
					state = PSTATE.DONE;
					break;

					default:
					throw new Error("Unexpected parameter");
				}
			}
		}

		var extraBindings:LocalBindingSet = new LocalBindingSet();
		if(f.nameSym){
			// Make this function available to itself..
			meth.nameLb = extraBindings.registerLocal(c.rt.nextID(), f.nameSym);
		}
		var bodyForms:ISeq = ISeq(RT.rest(form));

		Var.pushBindings(c.rt, RT.map(c.CURRENT_METHOD, meth));
		c.pushLocalBindingSet(meth.paramBindings);
		c.pushLocalBindingSet(extraBindings);
		Var.pushBindings(c.rt, RT.map(c.RECUR_ARGS, meth.paramBindings));
		meth.body = BodyExpr(BodyExpr.parse(c, C.RETURN, bodyForms));
		Var.popBindings(c.rt);
		c.popLocalBindingSet();
		c.popLocalBindingSet();
		Var.popBindings(c.rt);


		return meth;
	}

	public function emit(context:C, methGen:CodeGen):void{
		methGen.pushThisScope();
		if(this.hasNestedFn) methGen.pushNewActivationScope();

		var i:int = 1;
		reqParams.each(function(b:LocalBinding):void{
				b.runtimeValue = RuntimeLocal.fromTmp(methGen, i, b.runtimeName);
				i++;
			});

		if(restParam){
			methGen.asm.I_getlocal(i); // get arguments object
			methGen.restFromArguments(i - 1);
			restParam.runtimeValue = RuntimeLocal.fromTOS(methGen, restParam.runtimeName);
		}

		var nameSlot:int;
		if(nameLb){
			methGen.asm.I_getlocal(i); // get arguments object
 			methGen.asm.I_getproperty(methGen.emitter.nameFromIdent("callee"));
			methGen.asm.I_setlocal(i); // store current function in place of arguments
			nameLb.runtimeValue = RuntimeLocal.fromTmp(methGen, i, nameLb.runtimeName);
		}
		
		var loopLabel:Object = methGen.asm.I_label(undefined);
		/* Note: Any instructions after this point will be executed on every recur loop.. */

		if(nameLb){/* We need to re-set name reference to current function on each recur cycle (into fresh activation..)*/
			nameLb.runtimeValue.updateFromTmp(methGen, i);
		}

		Var.pushBindings(_compiler.rt, RT.map(
				_compiler.RECURING_BINDER, this,
				_compiler.RECUR_LABEL, loopLabel
			));
		body.emit(C.RETURN, methGen);
		Var.popBindings(_compiler.rt);

		methGen.asm.I_returnvalue();

	}
	
	
}

class PSTATE{
	public static var REQ:PSTATE = new PSTATE();
	public static var REST:PSTATE = new PSTATE();
	public static var DONE:PSTATE = new PSTATE();
}
class FnExpr implements Expr{
	public var line:int;
	public var nameSym:Symbol;
	public var methods:IVector;
	public var constants:ISet;
	private var _compiler:Compiler;

	public function FnExpr(c:Compiler){
		_compiler = c;
	}

	public function get isVariadic():Boolean{
		return methods.count() > 1;
	}

	public static function parse(c:Compiler, context:C, form:ISeq):Expr{
		var f:FnExpr = new FnExpr(c);
		f.line = int(c.LINE.get()); 

		//arglist might be preceded by symbol naming this fn
		if(RT.second(form) is Symbol)
		{
			f.nameSym = Symbol(RT.second(form));
			form = RT.cons(c.rt.FN, RT.rest(RT.rest(form)));
		}

		//now (fn [args] body...) or (fn ([args] body...) ([args2] body2...) ...)
		//turn former into latter
		if(RT.second(form) is IVector){
			form = RT.list(c.rt.FN, RT.rest(form));
		}
		
		f.methods = RT.vector();

		Var.pushBindings(c.rt, RT.map(
 				c.FN_CONSTANTS, RT.set()
 			));
		for(var s:ISeq = RT.rest(form); s != null; s = RT.rest(s)){
			f.methods = f.methods.cons(FnMethod.parse(c, context, ISeq(s.first()), f));
		}
		var consts:ISet = ISet(c.FN_CONSTANTS.get());
		Var.popBindings(c.rt);

		f.constants = consts;

		return f;
	}


	public function interpret():Object{
		throw new Error("Interpretation not implemented for FnExpr.");
		return null;
	}

	// Not being used
	public function emitConstCaching(gen:CodeGen):void{
 		this.constants.each(function(ea:Object):void{
 				gen.cacheConstant(ea);
 			});
	}

	public function emit(context:C, gen:CodeGen):void{
		var name:String = (this.nameSym ? this.nameSym.name : "anonymous") + "_at_" + this.line;
		var methGen:CodeGen;
		var argumentsObjIndex:int;
		var formalsTypes:Array = [];
		if(methods.count() == 1){
			var meth:FnMethod = FnMethod(methods.nth(0));

			meth.reqParams.each(function(ea:Object):void{
					formalsTypes.push(0/*'*'*/); 
				});
			methGen = gen.newMethodCodeGen(
				formalsTypes,
				false,
				true,
				gen.asm.currentScopeDepth, 
				name
			);
 			meth.startLabel = methGen.asm.newLabel();

			methGen.cacheStaticsClass();
			methGen.cacheRTInstance();

 			var arity:int = meth.reqParams.count();
 			argumentsObjIndex = arity + 1;

 			methGen.asm.I_getlocal(argumentsObjIndex);
 			methGen.asm.I_getproperty(methGen.emitter.nameFromIdent("length"));
 			methGen.asm.I_pushuint(methGen.emitter.constants.uint32(arity));

   			if(meth.restParam){
   				methGen.asm.I_ifge(meth.startLabel);
				methGen.throwError("Function invoked with invalid arity, expecting at least " + arity + " argument(s).");
    		}
    		else{
                methGen.asm.I_ifeq(meth.startLabel);
				methGen.throwError("Function invoked with invalid arity, expecting " + arity + " argument(s).");
  			}

 			methGen.asm.I_label(meth.startLabel);
			meth.emit(context, methGen);

			gen.asm.I_newfunction(methGen.meth.finalize());
		}
		else{ // Function is variadic, we must dispatch at runtime to the correct method...
			methGen = gen.newMethodCodeGen(formalsTypes, false, true, gen.asm.currentScopeDepth, name);
			var maxArity:int = 0;
			methods.each(function(meth:FnMethod):void{ maxArity = Math.max(maxArity, meth.reqParams.count());});
			methGen.asm.useTempRange(0, maxArity + 2); /*Reserve room for: this, param1, param2, paramN, Arguments. */

			methGen.cacheStaticsClass();
			methGen.cacheRTInstance();

			argumentsObjIndex = 1;

			// Initialize all the methods
			methods.each(function(meth:FnMethod):void{
					meth.startLabel = methGen.asm.newLabel(); 
				});

			methods.each(function(meth:FnMethod):void{  
					methGen.asm.I_getlocal(argumentsObjIndex);
					methGen.asm.I_getproperty(methGen.emitter.nameFromIdent("length"));
					if(meth.restParam){
						var minArity:int = meth.reqParams.count();
						methGen.asm.I_pushuint(methGen.emitter.constants.uint32(minArity));
						methGen.asm.I_ifge(meth.startLabel);
					}
					else{
						var arity:int = meth.reqParams.count();
						methGen.asm.I_pushuint(methGen.emitter.constants.uint32(arity));
						methGen.asm.I_ifeq(meth.startLabel);
					}
				});

			// If # of params at runtime doesn't match any of the overloads..
			methGen.throwError("Variadic function invoked with invalid arity.");

			methods.each(function(meth:FnMethod):void{

					methGen.asm.I_label(meth.startLabel);

					var j:int = 1;
					var i:int = argumentsObjIndex;
					methGen.asm.I_getlocal(i);
					meth.reqParams.each(function(ea:Object):void{
							methGen.asm.I_dup(); // Keep a copy of the arguments object.
							methGen.asm.I_pushint(methGen.emitter.constants.int32(j));
							methGen.asm.I_nextvalue();
							methGen.asm.I_setlocal(i);
							i++;
							j++;
						});
					// Now put the arguments object back into the locals, following all the params
					methGen.asm.I_setlocal(i);
					meth.emit(context, methGen);
				});
			
			gen.asm.I_newfunction(methGen.meth.finalize());
		}

		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}

}



class LetExpr implements Expr{
	public var bindingInits:LocalBindingSet;
	public var body:Expr;
	private var _compiler:Compiler;

	public function LetExpr(c:Compiler, bindingInits:LocalBindingSet, body:Expr){
		_compiler = c;
		this.bindingInits = bindingInits;
		this.body = body;
	}

	public static function parse(c:Compiler, context:C, frm:Object):Expr{
		var form:ISeq = ISeq(frm);
		//(let [var val var2 val2 ...] body...)

		if(!(RT.second(form) is IVector))
		throw new Error("IllegalArgumentException: Bad binding form, expected vector");

		var bindings:IVector = IVector(RT.second(form));
		if((bindings.count() % 2) != 0)
		throw new Error("IllegalArgumentException: Bad binding form, expected matched symbol expression pairs.");

		var body:ISeq = RT.rest(RT.rest(form));

		if(context == C.INTERPRET)
		return c.analyze(context, RT.list(RT.list(c.rt.FN, RT.vector(), form)));

		var lbs:LocalBindingSet = new LocalBindingSet();
		c.pushLocalBindingSet(lbs);
		for(var i:int = 0; i < bindings.count(); i += 2){
			if(!(bindings.nth(i) is Symbol))
			throw new Error("IllegalArgumentException: Bad binding form, expected symbol, got: " + bindings.nth(i));
			var sym:Symbol = Symbol(bindings.nth(i));
			if(sym.getNamespace() != null)
			throw new Error("Can't let qualified name");
			var init:Expr = c.analyze(C.EXPRESSION, bindings.nth(i + 1), sym.name);
			c.registerLocal(c.rt.nextID(), sym, init);
		}

		var bodyExpr:BodyExpr = BodyExpr(BodyExpr.parse(c, context, body));

		c.popLocalBindingSet();

		return new LetExpr(c, lbs, bodyExpr);
	}


	public function interpret():Object{
		throw new Error("UnsupportedOperationException: Can't eval let/loop");
	}

	public function emit(context:C, gen:CodeGen):void{
		this.bindingInits.eachWithIndex(function(sym:Symbol, b:LocalBinding, i:int){
				if(b){
					b.init.emit(C.EXPRESSION, gen);
					b.runtimeValue = RuntimeLocal.fromTOS(gen, b.runtimeName);
				}
			});
		body.emit(context, gen);
	}

}



class InvokeExpr implements Expr{
	public var fexpr:Expr;
	public var args:IVector;
	private var _compiler:Compiler;

	public function InvokeExpr(c:Compiler, fexpr:Expr, args:IVector){
		this.fexpr = fexpr;
		this.args = args;
		_compiler = c;
	}

	public function interpret():Object{
		var fn:Function = fexpr.interpret() as Function;
		var argvs:IVector = RT.vector();
		for(var i:int = 0; i < args.count(); i++){
			argvs = argvs.cons(Expr(args.nth(i)).interpret());
		}
		return fn.apply(null, argvs);
	}

	public function emit(context:C, gen:CodeGen):void{
		fexpr.emit(C.EXPRESSION, gen);

		/* Invoke an AS3 function or anything that happens to implement IFn. */
		var isFunLabel:Object = gen.asm.newLabel();
		gen.asm.I_coerce_a();
		gen.asm.I_dup();
		gen.asm.I_astype(gen.emitter.qname({ns: "com.las3r.runtime", id:"IFn"}, false));
		gen.asm.I_iffalse(isFunLabel);
		gen.asm.I_getproperty(gen.emitter.nameFromIdent("invoke" + args.count()));
		gen.asm.I_label(isFunLabel);

		gen.asm.I_pushnull(); // <-- the receiver
		for(var i:int = 0; i < args.count(); i++)
		{
			var e:Expr = Expr(args.nth(i));
			e.emit(C.EXPRESSION, gen);
		}
		gen.asm.I_call(args.count());
		if(context == C.STATEMENT){ gen.asm.I_pop(); }
	}

	public static function parse(c:Compiler, context:C, form:ISeq):Expr{
		if(context != C.INTERPRET){
			context = C.EXPRESSION;
		}
		var fexpr:Expr = c.analyze(context, form.first());
		var args:IVector = RT.vector();
		for(var s:ISeq = RT.seq(form.rest()); s != null; s = s.rest())
		{
			args = args.cons(c.analyze(context, s.first()));
		}

		if(args.count() > Compiler.MAX_POSITIONAL_ARITY){ throw new Error("IllegalStateException: Invoking Arity greater than " + Compiler.MAX_POSITIONAL_ARITY + " not supported"); }

		return new InvokeExpr(c, fexpr, args);
	}
}


class LocalBindingSet{

	private var _lbs:IVector;
	
	public function LocalBindingSet(){
		_lbs = RT.vector();
	}

	public function count():int{
		return _lbs.count();
	}

	public function bindingFor(sym:Symbol):LocalBinding{
		for(var i:int = _lbs.count() - 1; i > -1; i--){
			var lb:LocalBinding = LocalBinding(_lbs.nth(i));
			if(Util.equal(lb.sym, sym)){
				return lb;
			}
		}
		return null;
	}

	public function registerLocal(num:int, sym:Symbol, init:Expr = null):LocalBinding{
		var lb:LocalBinding = new LocalBinding(num, sym, init);
		_lbs = _lbs.cons(lb);
		return lb;
	}

	public function each(iterator:Function):void{
		_lbs.each(function(lb:LocalBinding):void{
				iterator(lb.sym, lb);
			});
	}

	public function eachWithIndex(iterator:Function):void{
		var i:int = 0;
		_lbs.each(function(lb:LocalBinding):void{
				iterator(lb.sym, lb, i);
				i += 1;
			});
	}

	public function eachReversedWithIndex(iterator:Function):void{
		for(var i:int = _lbs.count() - 1; i > -1; i--){
			var lb:LocalBinding = LocalBinding(_lbs.nth(i));
			iterator(lb.sym, lb, i);
		}
	}
	
}


class LocalBinding{
	public var sym:Symbol;
	public var runtimeName:String;
	public var runtimeValue:RuntimeLocal;
	public var init:Expr;

	public function LocalBinding(num:int, sym:Symbol, init:Expr = null){
		this.sym = sym;
		this.runtimeName = "local" + num;
		this.init = init;
	}

}


class LocalBindingExpr implements Expr{
	public var b:LocalBinding;

	public function LocalBindingExpr(b:LocalBinding){
		this.b = b;
	}

	public function interpret():Object{
		throw new Error("UnsupportedOperationException: Can't interpret locals");
	}

	public function emit(context:C, gen:CodeGen):void{
		if(context != C.STATEMENT){
			b.runtimeValue.get(gen);
		}
	}
}




class AssignExpr implements Expr{
	public var target:AssignableExpr;
	public var val:Expr;

	public function AssignExpr(target:AssignableExpr, val:Expr){
		this.target = target;
		this.val = val;
	}

	public function interpret():Object{
		return target.interpretAssign(val);
	}

	public function emit(context:C, gen:CodeGen):void{
		target.emitAssign(context, gen, val);
	}

	public static function parse(c:Compiler, context:C, frm:Object):Expr{
		var form:ISeq = ISeq(frm);
		if(RT.length(form) != 3)
		throw new Error("IllegalArgumentException: Malformed assignment, expecting (set! target val)");
		var target:Expr = c.analyze(C.EXPRESSION, RT.second(form));
		if(!(target is AssignableExpr))
		throw new Error("IllegalArgumentException: Invalid assignment target");
		return new AssignExpr(AssignableExpr(target), c.analyze(C.EXPRESSION, RT.third(form)));
	}
}




class VectorExpr implements Expr{
	public var args:IVector;

	public function VectorExpr(args:IVector){
		this.args = args;
	}

	public function interpret():Object{
		var ret:IVector = RT.vector();
		for(var i:int = 0; i < args.count(); i++)
		ret = IVector(ret.cons(Expr(args.nth(i)).interpret()));
		return ret;
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.getRTClass();
		for(var i:int = 0; i < args.count(); i++){
			Expr(args.nth(i)).emit(C.EXPRESSION, gen);
		}
		gen.newVector(this.args.count());
		if(context == C.STATEMENT) { gen.asm.I_pop();}
	}

	public static function parse(c:Compiler, context:C, form:IVector):Expr{
		var args:IVector = RT.vector();
		for(var i:int = 0; i < form.count(); i++){
			args = IVector(args.cons(c.analyze(context == C.INTERPRET ? context : C.EXPRESSION, form.nth(i))));
		}
		return new VectorExpr(args);
	}

}




class MapExpr implements Expr{
	public var keyvals:IVector;

	public function MapExpr(keyvals:IVector){
		this.keyvals = keyvals;
	}

	public function interpret():Object{
		var m:IMap = RT.map();
		for(var i:int = 0; i < keyvals.count(); i += 2){
			var key:Object = Expr(keyvals.nth(i)).interpret();
			var val:Object = Expr(keyvals.nth(i + 1)).interpret();
			m = m.assoc(key, val);
		}
		return m;
	}

	public function emit(context:C, gen:CodeGen):void{
		gen.getRTClass();
		for(var i:int = 0; i < keyvals.count(); i++){
			Expr(keyvals.nth(i)).emit(C.EXPRESSION, gen);
		}
		gen.newMap(this.keyvals.count());
		if(context == C.STATEMENT) { gen.asm.I_pop();}
	}

	public static function parse(c:Compiler, context:C, form:IMap):Expr{
		var keyvals:IVector = RT.vector();
		form.each(function(key:Object, val:Object):void{
				keyvals = keyvals.cons(c.analyze(context == C.INTERPRET ? context : C.EXPRESSION, key));
				keyvals= keyvals.cons(c.analyze(context == C.INTERPRET ? context : C.EXPRESSION, val));
			});
		return new MapExpr(keyvals);
	}
}




class RecurExpr implements Expr{
	public var args:IVector;
	public var loopLocals:LocalBindingSet;
	private var _compiler:Compiler;

	public function RecurExpr(c:Compiler, loopLocals:LocalBindingSet, args:IVector){
		_compiler = c;
		this.loopLocals = loopLocals;
		this.args = args;
	}

	public function interpret():Object{
		throw new Error("UnsupportedOperationException: Can't eval recur");
	}

	public function emit(context:C, gen:CodeGen):void{
		var loopLabel:Object = _compiler.RECUR_LABEL.get();
		if(loopLabel == null){
			throw new Error("IllegalStateException: No loop label found for recur.");
		}

		// First push all the evaluated recur args onto the stack
		this.loopLocals.eachWithIndex(function(sym:Symbol, lb:LocalBinding, i:int){
				var arg:Expr = Expr(args.nth(i));
				arg.emit(C.EXPRESSION, gen);
			});

		
		// if binding form is a function, replace the current activation with a fresh one
		if(_compiler.RECURING_BINDER.isBound() && _compiler.RECURING_BINDER.get() is FnMethod){
			var m:FnMethod = FnMethod(_compiler.RECURING_BINDER.get());
			if(m.hasNestedFn){
				gen.refreshCurrentActivationScope();
			}
		}

		/******    TODO: Need to clear locals here?   ****/

		// then fill it up with the recur args.
		this.loopLocals.eachReversedWithIndex(function(sym:Symbol, lb:LocalBinding, i:int){
				lb.runtimeValue.updateFromTOS(gen);
			});
		gen.asm.I_jump(loopLabel);
	}


	public static function parse(c:Compiler, context:C, frm:Object):Expr{
		var form:ISeq = ISeq(frm);
		if(!c.RECUR_ARGS.isBound())
		throw new Error("UnsupportedOperationException: Can only recur from within a function expression.");
		var loopLocals:LocalBindingSet = LocalBindingSet(c.RECUR_ARGS.get());
		if(context != C.RETURN || loopLocals == null)
		throw new Error("UnsupportedOperationException: Can only recur from tail position. Found in context: " + context);
		if(c.IN_CATCH_FINALLY.get())
		throw new Error("UnsupportedOperationException: Cannot recur from catch/finally");
		var args:IVector = RT.vector();
		for(var s:ISeq = RT.seq(form.rest()); s != null; s = s.rest())
		{
			args = args.cons(c.analyze(C.EXPRESSION, s.first()));
		}
		if(args.count() != loopLocals.count())
		throw new Error("IllegalArgumentException: Mismatched argument count to recur, expected: " + loopLocals.count() + " args, got:" + args.count());
		return new RecurExpr(c, loopLocals, args);
	}
}



class HostExpr implements Expr{

	public function emit(context:C, gen:CodeGen):void{}

	public function interpret():Object {
		return null;
	}

	public static function parse(compiler:Compiler, context:C, frm:Object):Expr{
		var form:ISeq = ISeq(frm);
		//(. x fieldname-sym) or
		// (. x (methodname-sym args?))
		if(RT.length(form) < 3)
		throw new Error("IllegalArgumentException: Malformed member expression, expecting (. target field) or (. target (method args*))");

		var sym:Symbol;
		var c:Class;
		var instance:Expr;
		if(RT.length(form) == 3 && RT.third(form) is Symbol)    //field
		{
			sym = Symbol(RT.third(form));

			//determine static or instance
			//static target must be symbol, either fully.qualified.Classname or Classname that has been imported
			c = maybeClass(compiler, RT.second(form), false);
			if(c != null)
			return new StaticFieldExpr(compiler, c, sym.name);
			
			instance = compiler.analyze(context == C.INTERPRET ? context : C.EXPRESSION, RT.second(form));
			return new InstanceFieldExpr(compiler, instance, sym.name);
		}
		else // method call
		{
			var call:ISeq = ISeq(RT.third(form))
			if(!(RT.first(call) is Symbol))
			throw new Error("IllegalArgumentException: Malformed member expression");

			sym = Symbol(RT.first(call));

			var args:IVector = RT.vector();
			for(var s:ISeq = RT.rest(call); s != null; s = s.rest()){
				args = args.cons(compiler.analyze(context == C.INTERPRET ? context : C.EXPRESSION, s.first()));
			}

			c = maybeClass(compiler, RT.second(form), false);
			if(c != null)
			return new StaticMethodExpr(compiler, c, sym.name, args);

			instance = compiler.analyze(context == C.INTERPRET ? context : C.EXPRESSION, RT.second(form));
			return new InstanceMethodExpr(compiler, instance, sym.name, args);
		}
	}

	public static function maybeClass(compiler:Compiler, form:Object, stringOk:Boolean):Class{
		if(form is Class)
		return Class(form);
		var c:Class = null;
		if(form is Symbol)
		{
			var sym:Symbol = Symbol(form);
			if(sym.ns == null) //if ns-qualified can't be classname
			{
				if(sym.name.indexOf('.') > 0 || sym.name.charAt(0) == '['){
						c = RT.classForName(sym.name);
					}
					else
					{
						var o:Object = compiler.currentNS().getMapping(sym);
						if(o is Class)
						c = Class(o);
					}
				}
			}
			else if(stringOk && form is String)
			c = RT.classForName(String(form));
			return c;
		}


	}



	class StaticMethodExpr extends HostExpr{
		public var methName:String;
		public var c:Class;
		public var args:IVector;
		private var _compiler:Compiler;

		public function StaticMethodExpr(compiler:Compiler, c:Class, methName:String, args:IVector){
			_compiler = compiler;
			this.methName = methName;
			this.c = c;
			_compiler.registerConstant(c);
			this.args = args;
		}

		override public function interpret():Object{
			return c[this.methName].apply(null, args.collect(function(ea:*):*{ return ea.interpret(); }));
		}

		override public function emit(context:C, gen:CodeGen):void{
			gen.emitConstant(this.c);
			this.args.each(function(ea:Expr):void{ ea.emit(C.EXPRESSION, gen); })
			gen.asm.I_callproperty(gen.emitter.nameFromIdent(this.methName), args.count());
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}

	}


	class InstanceMethodExpr extends HostExpr{
		public var methName:String;
		public var target:Expr;
		public var args:IVector;
		private var _compiler:Compiler;

		public function InstanceMethodExpr(compiler:Compiler, target:Expr, methName:String, args:IVector){
			_compiler = compiler;
			this.methName = methName;
			this.target = target;
			this.args = args;
		}

		override public function interpret():Object{
			return (target.interpret())[this.methName].apply(null, args.collect(function(ea:*):*{ return ea.interpret(); }));
		}

		override public function emit(context:C, gen:CodeGen):void{
			target.emit(C.EXPRESSION, gen);
			this.args.each(function(ea:Expr):void{ ea.emit(C.EXPRESSION, gen); })
			gen.asm.I_callproperty(gen.emitter.nameFromIdent(this.methName), args.count());
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}

	}




	class StaticFieldExpr extends HostExpr implements AssignableExpr{
		public var fieldName:String;
		public var c:Class;
		private var _compiler:Compiler;

		public function StaticFieldExpr(compiler:Compiler, c:Class, fieldName:String){
			_compiler = compiler;
			this.fieldName = fieldName;
			this.c = c;
			_compiler.registerConstant(c);
		}

		override public function interpret():Object{
			return c[this.fieldName];
		}

		public function interpretAssign(val:Expr):Object{
			return c[this.fieldName] = val.interpret();
		}


		override public function emit(context:C, gen:CodeGen):void{
			gen.emitConstant(this.c);
			gen.asm.I_getproperty(gen.emitter.nameFromIdent(this.fieldName));
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}


		public function emitAssign(context:C, gen:CodeGen, val:Expr):void{
			gen.emitConstant(this.c);
			gen.asm.I_dup();
			val.emit(C.EXPRESSION, gen);
			gen.asm.I_setproperty(gen.emitter.nameFromIdent(this.fieldName));
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}
	}



	class InstanceFieldExpr extends HostExpr implements AssignableExpr{
		public var fieldName:String;
		public var target:Expr;
		private var _compiler:Compiler;

		public function InstanceFieldExpr(compiler:Compiler, target:Expr, fieldName:String){
			_compiler = compiler;
			this.target = target;
			this.fieldName = fieldName;
		}

		override public function interpret():Object{
			return this.target[this.fieldName];
		}

		public function interpretAssign(val:Expr):Object{
			return this.target[this.fieldName] = val.interpret();
		}

		override public function emit(context:C, gen:CodeGen):void{
			target.emit(C.EXPRESSION, gen);
			gen.asm.I_getproperty(gen.emitter.nameFromIdent(this.fieldName));
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}


		public function emitAssign(context:C, gen:CodeGen, val:Expr):void{
			target.emit(C.EXPRESSION, gen);
			gen.asm.I_dup();
			val.emit(C.EXPRESSION, gen);
			gen.asm.I_setproperty(gen.emitter.nameFromIdent(this.fieldName));
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}
	}


	class NewExpr implements Expr{
		public var args:IVector;
		public var target:Expr;
		private var _compiler:Compiler;

		public function NewExpr(compiler:Compiler, target:Expr, args:IVector){
			this.args = args;
			this.target = target;
			_compiler = compiler;
		}

		public function interpret():Object{
			throw new Error("Interpretation of NewExpr not supported.");
		}

		public function emit(context:C, gen:CodeGen):void{
			target.emit(C.EXPRESSION, gen);
			this.args.each(function(ea:Expr):void{ ea.emit(C.EXPRESSION, gen); });
			gen.asm.I_construct(args.count());
			if(context == C.STATEMENT){ gen.asm.I_pop(); }
		}

		public static function parse(compiler:Compiler, context:C, frm:Object):Expr{
			var form:ISeq = ISeq(frm);
			//(new classExpr args...)
			if(form.count() < 2)
			throw new Error("Wrong number of arguments, expecting: (new classExpr args...)");
			var target:Expr = compiler.analyze(C.EXPRESSION, RT.second(form));
			var args:IVector = RT.vector();
			for(var s:ISeq = RT.rest(RT.rest(form)); s != null; s = s.rest()){
				args = args.cons(compiler.analyze(C.EXPRESSION, s.first()));
			}
			return new NewExpr(compiler, target, args);
		}
	}

	class ThrowExpr extends UntypedExpr{
		public var excExpr:Expr;

		public function ThrowExpr(excExpr:Expr){
			this.excExpr = excExpr;
		}

		override public function interpret():Object{
			throw new Error("Can't interpret a throw.");
		}

		override public function emit(context:C, gen:CodeGen):void{
			// So there's a nil on the stack after the exception is thrown,
			// required so that in the event that the try is prematurely aborted (because of
				// this throw) there will still be something on the stack to match the catch's
			// result.
			gen.asm.I_pushnull();
			// Then, reconcile with type of ensuing catch expr...
			gen.asm.I_coerce_a(); 
			excExpr.emit(context, gen);
			gen.asm.I_throw();
		}

		public static function parse(c:Compiler, context:C, form:Object):Expr{
			if(context == C.INTERPRET)
			return c.analyze(context, RT.list(RT.list(c.rt.FN, RT.vector(), form)));
			return new ThrowExpr(c.analyze(context, RT.second(form)));
		}

	}


	class CatchClause{
		//final String className;
		public var c:Class;
		public var className:String;
		public var lb:LocalBinding;
		public var handler:Expr;
		public var label:Object;
		public var endLabel:Object;

		public function CatchClause(c:Class, className:String, lb:LocalBinding, handler:Expr){
			this.c = c;
			this.lb = lb;
			this.handler = handler;
			this.className = className;
		}
	}


	class TryExpr implements Expr{
		public var tryExpr:Expr;
		public var catchExprs:IVector;
		public var finallyExpr:Expr;
		private var _compiler:Compiler;


		public function TryExpr(c:Compiler, tryExpr:Expr, catchExprs:IVector, finallyExpr:Expr){
			_compiler = c;
			this.tryExpr = tryExpr;
			this.catchExprs = catchExprs;
			this.finallyExpr = finallyExpr;
		}

		public function interpret():Object{
			throw new Error("UnsupportedOperationException: Can't eval try");
		}

		public function emit(context:C, gen:CodeGen):void{			
			var endClauses:Object = gen.asm.newLabel();
			var finallyLabel:Object = gen.asm.newLabel();
			var end:Object = gen.asm.newLabel();
			for(var i:int = 0; i < catchExprs.count(); i++)
			{
				var clause:CatchClause = CatchClause(catchExprs.nth(i));
				clause.label = gen.asm.newLabel();
				clause.endLabel = gen.asm.newLabel();
			}
			var tryStart:Object = gen.asm.I_label(undefined);
			tryExpr.emit(context, gen);
			gen.asm.I_coerce_a(); // Reconcile with return type of catch expr..
			var tryEnd:Object = gen.asm.I_label(undefined);
			if(finallyExpr != null){
				gen.asm.I_pop();
				gen.asm.I_jump(finallyLabel);
			}
			else{
				gen.asm.I_jump(end);
			}
			var catchStart:Object = gen.asm.I_label(undefined);

			if(catchExprs.count() > 0){
				var excId:int = gen.meth.addException(new ABCException(
						tryStart.address, 
						tryEnd.address, 
						catchStart.address, 
						0, // *
						gen.emitter.nameFromIdent("catch")
					));

				gen.asm.startCatch(); // Increment max stack by 1, for exception object
				gen.restoreScopeStack(); // Scope stack is wiped on exception, so we reinstate it..
				gen.pushCatchScope(excId); 

				
				for(i = 0; i < catchExprs.count(); i++)
				{
					clause = CatchClause(catchExprs.nth(i));
					gen.asm.I_label(clause.label);

					// Exception object should be on top of operand stack...
					gen.asm.I_dup();
					gen.asm.I_istype(gen.emitter.nameFromIdent(clause.className));
					gen.asm.I_iffalse(clause.endLabel);

					// Store the exception in local value
					var b:LocalBinding = clause.lb;
					b.runtimeValue = RuntimeLocal.fromTOS(gen, b.runtimeName);

					clause.handler.emit(context, gen);
					gen.asm.I_coerce_a();// Reconcile with return type of preceding try expr..

					gen.asm.I_jump(endClauses);

					gen.asm.I_label(clause.endLabel);
				}
				// If none of the catch clauses apply, rethrow the exception.
				gen.asm.I_throw();

				gen.asm.I_label(endClauses);
				// Pop the catch scope..
				gen.popScope(); 
				if(finallyExpr != null){
					gen.asm.I_pop();
					gen.asm.I_jump(finallyLabel);
				}
				else{
					gen.asm.I_jump(end);
				}

			}
			if(finallyExpr != null)
			{
				gen.asm.I_label(finallyLabel);
				finallyExpr.emit(context, gen);
				gen.asm.I_coerce_a();// Reconcile with return types of preceding try/catch exprs..
			}
			gen.asm.I_label(end);
			if(context == C.STATEMENT){ gen.asm.I_pop(); }

		}


		public static function parse(c:Compiler, context:C, frm:Object):Expr{
			var form:ISeq = ISeq(frm);
			if(context != C.RETURN)
			return c.analyze(context, RT.list(RT.list(c.rt.FN, RT.vector(), form)));

			//(try try-expr* catch-expr* finally-expr?)
			//catch-expr: (catch class sym expr*)
			//finally-expr: (finally expr*)

			var body:IVector = RT.vector();
			var catches:IVector = RT.vector();
			var finallyExpr:Expr = null;
			var caught:Boolean = false;

			for(var fs:ISeq = form.rest(); fs != null; fs = fs.rest())
			{
				var f:Object = fs.first();
				var op:Object = (f is ISeq) ? ISeq(f).first() : null;
				if(!Util.equal(op, c.rt.CATCH) && !Util.equal(op, c.rt.FINALLY))
				{
					if(caught)
					throw new Error("Only catch or finally clause can follow catch in try expression");
					body = body.cons(f);
				}
				else
				{
					if(Util.equal(op, c.rt.CATCH))
					{
						var className:Symbol = Symbol(RT.second(f));
						var klass:Class = HostExpr.maybeClass(c, className, false);
						if(klass == null)
						throw new Error("IllegalArgumentException: Unable to resolve classname: " + RT.second(f));
						if(!(RT.third(f) is Symbol))
						throw new Error("IllegalArgumentException: Bad binding form, expected symbol, got: " + RT.third(f));
						var sym:Symbol = Symbol(RT.third(f));
						if(sym.getNamespace() != null)
						throw new Error("Can't bind qualified name:" + sym);

						c.pushLocalBindingSet(new LocalBindingSet());
						var lb:LocalBinding = c.registerLocal(c.rt.nextID(), sym);
						Var.pushBindings(c.rt, RT.map(c.IN_CATCH_FINALLY, true));
						var handler:Expr = BodyExpr.parse(c, context, RT.rest(RT.rest(RT.rest(f))));
						Var.popBindings(c.rt);
						c.popLocalBindingSet();

						catches = catches.cons(new CatchClause(klass, className.toString(), lb, handler));
						caught = true;
					}
					else //finally
					{
						if(fs.rest() != null)
						throw new Error("Finally clause must be last in try expression");
						Var.pushBindings(c.rt, RT.map(c.IN_CATCH_FINALLY, true));
						finallyExpr = BodyExpr.parse(c, C.STATEMENT, RT.rest(f));
						Var.popBindings(c.rt);
					}
				}
			}

			return new TryExpr(c, BodyExpr.parse(c, context, RT.seq(body)), catches, finallyExpr);
		}
	}


