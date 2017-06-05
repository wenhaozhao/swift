// RUN: %target-swift-frontend -enforce-exclusivity=checked -Onone -emit-sil -parse-as-library %s | %FileCheck %s
// REQUIRES: asserts

// This tests SILGen and AccessEnforcementSelection as a single set of tests.
// (Some static/dynamic enforcement selection is done in SILGen, and some is
// deferred. That may change over time but we want the outcome to be the same).
//
// Each FIXME line is a case that the current implementation misses.
// The model is currently being refined, so this isn't set in stone.
//
// TODO: Move all static cases (search for // Error:) into
// a set of -verify tests (noescape_static_diagnostics.swift).
// and a set of separate SILGen-only tests to check [unknown] markers.
//
// TODO: Ensure that each dynamic case is covered by
// Interpreter/enforce_exclusive_access.swift.

// Helper
func doOne(_ f: () -> ()) {
  f()
}

// Helper
func doTwo(_: ()->(), _: ()->()) {}

// Helper
func doOneInout(_: ()->(), _: inout Int) {}

// FIXME: statically prohibit a call to a non-escaping closure
// parameter using another non-escaping closure parameter as an argument.
func reentrantNoescape(fn: (() -> ()) -> ()) {
  fn { fn {} }
}

// Error: Cannot capture nonescaping closure.
// func reentrantCapturedNoescape(fn: (() -> ()) -> ()) {
//   let c = { fn {} }
//   fn(c)
// }

// Helper
struct Frob {
  mutating func outerMut() { doOne { innerMut() } }
  mutating func innerMut() {}
}

// Allow nested mutable access via closures.
func nestedNoEscape(f: inout Frob) {
  doOne { f.outerMut() }
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape14nestedNoEscapeyAA4FrobVz1f_tF : $@convention(thin) (@inout Frob) -> () {
// CHECK-NOT: begin_access
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14nestedNoEscapeyAA4FrobVz1f_tF'

// closure #1 in nestedNoEscape(f:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape14nestedNoEscapeyAA4FrobVz1f_tFyycfU_ : $@convention(thin) (@inout_aliasable Frob) -> () {
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Frob
// CHECK: [[ACCESS:%.*]] = begin_access [modify]
// CHECK: %{{.*}} = apply %{{.*}}([[ACCESS]]) : $@convention(method) (@inout Frob) -> ()
// CHECK: end_access [[ACCESS]] : $*Frob
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14nestedNoEscapeyAA4FrobVz1f_tFyycfU_'

// Allow aliased noescape reads.
func readRead() {
  var x = 3
  // Around the call: [read] [static]
  // Inside each closure: [read] [static]
  doTwo({ _ = x }, { _ = x })
  x = 42
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape8readReadyyF : $@convention(thin) () -> () {
// CHECK: [[ALLOC:%.*]] = alloc_stack $Int, var, name "x"
// CHECK-NOT: begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] [[ALLOC]] : $*Int
// CHECK-NOT: begin_access [read] [dynamic]
// CHECK: apply
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape8readReadyyF'

// closure #1 in readRead()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape8readReadyyFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape8readReadyyFyycfU_'

// closure #2 in readRead()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape8readReadyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape8readReadyyFyycfU0_'

// Allow aliased noescape reads of an `inout` arg.
func inoutReadRead(x: inout Int) {
  // Around the call: [read] [static]
  // Inside each closure: [read] [static]
  doTwo({ _ = x }, { _ = x })
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape09inoutReadE0ySiz1x_tF : $@convention(thin) (@inout Int) -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape09inoutReadE0ySiz1x_tF'

// closure #1 in inoutReadRead(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape09inoutReadE0ySiz1x_tFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape09inoutReadE0ySiz1x_tFyycfU_'

// closure #2 in inoutReadRead(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape09inoutReadE0ySiz1x_tFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape09inoutReadE0ySiz1x_tFyycfU0_'

// Allow aliased noescape read + boxed read.
func readBoxRead() {
  var x = 3
  let c = { _ = x }
  // Inside may-escape closure `c`: [read] [dynamic]
  // Inside never-escape closure: [read] [dynamic]
  doTwo(c, { _ = x })
  x = 42
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape11readBoxReadyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape11readBoxReadyyF'

// closure #1 in readBoxRead()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape11readBoxReadyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [read] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape11readBoxReadyyFyycfU_'

// closure #2 in readBoxRead()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape11readBoxReadyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// FIXME-CHECK-LABEL: sil private @_T027access_enforcement_noescape11readBoxReadyyFyycfU0_ : $@convention(thin) (@owned { var Int }) -> () {
// FIXME-CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [dynamic] [[ADDR]] : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape11readBoxReadyyFyycfU0_'

// Error: cannout capture inout.
//
// func inoutReadReadBox(x: inout Int) {
//   let c = { _ = x }
//   doTwo({ _ = x }, c)
// }

// Allow aliased noescape read + write.
func readWrite() {
  var x = 3
  // Around the call: [modify] [static]
  // Inside closure 1: [read] [static]
  // Inside closure 2: [modify] [static]
  doTwo({ _ = x }, { x = 42 })
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape9readWriteyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape9readWriteyyF'

// closure #1 in readWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape9readWriteyyFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape9readWriteyyFyycfU_'

// closure #2 in readWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape9readWriteyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape9readWriteyyFyycfU0_'

// Allow aliased noescape read + write of an `inout` arg.
func inoutReadWrite(x: inout Int) {
  // Around the call: [modify] [static]
  // Inside closure 1: [read] [static]
  // Inside closure 2: [modify] [static]
  doTwo({ _ = x }, { x = 3 })
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape14inoutReadWriteySiz1x_tF : $@convention(thin) (@inout Int) -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14inoutReadWriteySiz1x_tF'

// closure #1 in inoutReadWrite(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape14inoutReadWriteySiz1x_tFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14inoutReadWriteySiz1x_tFyycfU_'

// closure #2 in inoutReadWrite(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape14inoutReadWriteySiz1x_tFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14inoutReadWriteySiz1x_tFyycfU0_'


// FIXME: Trap on aliased boxed read + noescape write.
//
// Note: There's no actual exclusivity danger here, because `c` is
// passed to a noescape argument and is never itself
// captured. However, SILGen conservatively assumes that the
// assignment `let c =` captures the closure. Later we could refine
// the rules to recognize obviously nonescpaping closures.
func readBoxWrite() {
  var x = 3
  let c = { _ = x }
  // Inside may-escape closure `c`: [read] [dynamic]
  // Inside never-escape closure: [modify] [dynamic]
  doTwo(c, { x = 42 })
}
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape12readBoxWriteyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// CHECK-NOT: begin_access
// CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readBoxWriteyyF'

// closure #1 in readBoxWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape12readBoxWriteyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [read] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readBoxWriteyyFyycfU_'

// closure #2 in readBoxWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape12readBoxWriteyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// FIXME-CHECK-LABEL: sil private @_T027access_enforcement_noescape12readBoxWriteyyFyycfU0_ : $@convention(thin) (@owned { var Int }) -> () {
// FIXME-CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [dynamic] [[ADDR]] : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readBoxWriteyyFyycfU0_'

// Error: cannout capture inout.
// func inoutReadBoxWrite(x: inout Int) {
//   let c = { _ = x }
//    doTwo({ x = 42 }, c)
// }

// FIXME: Trap on aliased noescape read + boxed write.
//
// See the note above.
func readWriteBox() {
  var x = 3
  let c = { x = 42 }
  // Inside may-escape closure `c`: [modify] [dynamic]
  // Inside never-escape closure: [read] [dynamic]
  doTwo({ _ = x }, c)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape12readWriteBoxyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// CHECK-NOT: begin_access
// CHECK: apply %{{.*}}([[PA2]], [[PA1]])
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readWriteBoxyyF'

// closure #1 in readWriteBox()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape12readWriteBoxyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readWriteBoxyyFyycfU_'

// closure #2 in readWriteBox()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape12readWriteBoxyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// FIXME-CHECK-LABEL: sil private @_T027access_enforcement_noescape12readWriteBoxyyFyycfU0_ : $@convention(thin) ((@owned { var Int }) -> () {
// FIXME-CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] [[ADDR]] : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape12readWriteBoxyyFyycfU0_'

// Error: cannout capture inout.
// func inoutReadWriteBox(x: inout Int) {
//   let c = { x = 42 }
//   doTwo({ _ = x }, c)
// }

// Error: noescape read + write inout.
func readWriteInout() {
  var x = 3
  // Around the call: [read] [static]
  // Around the call: [modify] [static] // Error
  // Inside closure: [modify] [static]
  doOneInout({ _ = x }, &x)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape14readWriteInoutyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: [[ACCESS2:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS2]])
// FIXME-CHECK: end_access [[ACCESS2]]
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14readWriteInoutyyF'

// closure #1 in readWriteInout()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape14readWriteInoutyyFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape14readWriteInoutyyFyycfU_'

// Error: noescape read + write inout of an inout.
func inoutReadWriteInout(x: inout Int) {
  // Around the call: [read] [static]
  // Around the call: [modify] [static] // Error
  // Inside closure: [modify] [static]
  doOneInout({ _ = x }, &x)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape19inoutReadWriteInoutySiz1x_tF : $@convention(thin) (@inout Int) -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: [[ACCESS2:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS2]])
// FIXME-CHECK: end_access [[ACCESS2]]
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape19inoutReadWriteInoutySiz1x_tF'

// closure #1 in inoutReadWriteInout(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape19inoutReadWriteInoutySiz1x_tFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [read] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [read] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape19inoutReadWriteInoutySiz1x_tFyycfU_'

// Trap on boxed read + write inout.
// FIXME: Passing a captured var as inout needs dynamic enforcement.
func readBoxWriteInout() {
  var x = 3
  let c = { _ = x }
  // Around the call: [modify] [dynamic]
  // Inside closure: [read] [dynamic]
  doOneInout(c, &x)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape17readBoxWriteInoutyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS]])
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape17readBoxWriteInoutyyF'

// closure #1 in readBoxWriteInout()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape17readBoxWriteInoutyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [read] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape17readBoxWriteInoutyyFyycfU_'

// Error: inout cannot be captured.
// func inoutReadBoxWriteInout(x: inout Int) {
//   let c = { _ = x }
//   doOneInout(c, &x)
// }

// Allow aliased noescape write + write.
func writeWrite() {
  var x = 3
  // Around the call: [modify] [static]
  // Inside closure 1: [modify] [static]
  // Inside closure 2: [modify] [static]
  doTwo({ x = 42 }, { x = 87 })
  _ = x
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape10writeWriteyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape10writeWriteyyF'

// closure #1 in writeWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape10writeWriteyyFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape10writeWriteyyFyycfU_'

// closure #2 in writeWrite()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape10writeWriteyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape10writeWriteyyFyycfU0_'

  
// Allow aliased noescape write + write of an `inout` arg.
func inoutWriteWrite(x: inout Int) {
  // Around the call: [modify] [static]
  // Inside closure 1: [modify] [static]
  // Inside closure 2: [modify] [static]
  doTwo({ x = 42}, { x = 87 })
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tF : $@convention(thin) (@inout Int) -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tF'

// closure #1 in inoutWriteWrite(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tFyycfU_'

// closure #2 in inoutWriteWrite(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape010inoutWriteE0ySiz1x_tFyycfU0_'

// FIXME: Trap on aliased boxed write + noescape write.
//
// See the note above.
func writeWriteBox() {
  var x = 3
  let c = { x = 87 }
  // Inside may-escape closure `c`: [modify] [dynamic]
  // Inside never-escape closure: [modify] [dynamic]
  doTwo({ x = 42 }, c)
  _ = x
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape13writeWriteBoxyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// CHECK: [[PA2:%.*]] = partial_apply
// FIXME-CHECK-NOT: begin_access
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[PA2]])
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape13writeWriteBoxyyF'

// closure #1 in writeWriteBox()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape13writeWriteBoxyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape13writeWriteBoxyyFyycfU_'

// closure #2 in writeWriteBox()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape13writeWriteBoxyyFyycfU0_ : $@convention(thin) (@inout_aliasable Int) -> () {
// FIXME-CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] [[ADDR]] : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape13writeWriteBoxyyFyycfU0_'

// Error: inout cannot be captured.
// func inoutWriteWriteBox(x: inout Int) {
//   let c = { x = 87 }
//   doTwo({ x = 42 }, c)
// }

// Error: on noescape write + write inout.
func writeWriteInout() {
  var x = 3
  // Around the call: [modify] [static]
  // Around the call: [modify] [static] // Error
  // Inside closure: [modify] [static]
  doOneInout({ x = 42 }, &x)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape15writeWriteInoutyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS1:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: [[ACCESS2:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS2]])
// FIXME-CHECK: end_access [[ACCESS2]]
// FIXME-CHECK: end_access [[ACCESS1]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape15writeWriteInoutyyF'

// closure #1 in writeWriteInout()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape15writeWriteInoutyyFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape15writeWriteInoutyyFyycfU_'

// Error: on noescape write + write inout.
func inoutWriteWriteInout(x: inout Int) {
  // Around the call: [modify] [static]
  // Around the call: [modify] [static] // Error
  // Inside closure: [modify] [static]
  doOneInout({ x = 42 }, &x)
}

// inoutWriteWriteInout(x:)
// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape010inoutWriteE5InoutySiz1x_tF : $@convention(thin) (@inout Int) -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: [[ACCESS2:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS2]])
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: // end sil function '_T027access_enforcement_noescape010inoutWriteE5InoutySiz1x_tF'

// closure #1 in inoutWriteWriteInout(x:)
// CHECK-LABEL: sil private @_T027access_enforcement_noescape010inoutWriteE5InoutySiz1x_tFyycfU_ : $@convention(thin) (@inout_aliasable Int) -> () {
// CHECK-NOT: [[ACCESS:%.*]] = begin_access [modify] [dynamic]
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [static] %0 : $*Int
// FIXME-CHECK: end_access [[ACCESS]] 
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape010inoutWriteE5InoutySiz1x_tFyycfU_'

// Trap on boxed write + write inout.
// FIXME: Passing a captured var as inout needs dynamic enforcement.
func writeBoxWriteInout() {
  var x = 3
  let c = { x = 42 }
  // Around the call: [modify] [dynamic]
  // Inside closure: [modify] [dynamic]
  doOneInout(c, &x)
}

// CHECK-LABEL: sil hidden @_T027access_enforcement_noescape18writeBoxWriteInoutyyF : $@convention(thin) () -> () {
// CHECK: [[PA1:%.*]] = partial_apply
// FIXME-CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] %0 : $*Int
// FIXME-CHECK: apply %{{.*}}([[PA1]], [[ACCESS]])
// FIXME-CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape18writeBoxWriteInoutyyF'

// closure #1 in writeBoxWriteInout()
// CHECK-LABEL: sil private @_T027access_enforcement_noescape18writeBoxWriteInoutyyFyycfU_ : $@convention(thin) (@owned { var Int }) -> () {
// CHECK: [[ADDR:%.*]] = project_box %0 : ${ var Int }, 0
// CHECK: [[ACCESS:%.*]] = begin_access [modify] [dynamic] [[ADDR]] : $*Int
// CHECK: end_access [[ACCESS]]
// CHECK-LABEL: } // end sil function '_T027access_enforcement_noescape18writeBoxWriteInoutyyFyycfU_'

// Error: Cannot capture inout
// func inoutWriteBoxWriteInout(x: inout Int) {
//   let c = { x = 42 }
//   doOneInout(c, &x)
// }
