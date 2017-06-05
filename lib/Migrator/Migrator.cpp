//===--- Migrator.cpp -----------------------------------------------------===//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "swift/Frontend/Frontend.h"
#include "swift/Migrator/ASTMigratorPass.h"
#include "swift/Migrator/EditorAdapter.h"
#include "swift/Migrator/FixitApplyDiagnosticConsumer.h"
#include "swift/Migrator/Migrator.h"
#include "swift/Migrator/RewriteBufferEditsReceiver.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Edit/EditedSource.h"
#include "clang/Rewrite/Core/RewriteBuffer.h"
#include "llvm/Support/FileSystem.h"

using namespace swift;
using namespace swift::migrator;

bool migrator::updateCodeAndEmitRemap(CompilerInstance *Instance,
                                      const CompilerInvocation &Invocation) {
  Migrator M { Instance, Invocation }; // Provide inputs and configuration

  // Phase 1: Pre Fix-it passes
  // These uses the initial frontend invocation to apply any obvious fix-its
  // to see if we can get an error-free AST to get to Phase 2.
  std::unique_ptr<swift::CompilerInstance> PreFixItInstance;
  if (Instance->getASTContext().hadError()) {
    PreFixItInstance = M.repeatFixitMigrations(2,
      Invocation.getLangOptions().EffectiveLanguageVersion);

    // If we still couldn't fix all of the errors, give up.
    if (PreFixItInstance == nullptr ||
        !PreFixItInstance->hasASTContext() ||
        PreFixItInstance->getASTContext().hadError()) {
      return true;
    }
    M.StartInstance = PreFixItInstance.get();
  }

  // Phase 2: Syntactic Transformations
  auto FailedSyntacticPasses = M.performSyntacticPasses();
  if (FailedSyntacticPasses) {
    return true;
  }

  // Phase 3: Post Fix-it Passes
  // Perform fix-it based migrations on the compiler, some number of times in
  // order to give the compiler an opportunity to
  // take its time reaching a fixed point.
  // This is the end of the pipeline, so we throw away the compiler instance(s)
  // we used in these fix-it runs.

  if (M.getMigratorOptions().EnableMigratorFixits) {
    M.repeatFixitMigrations(Migrator::MaxCompilerFixitPassIterations,
                            {4, 0, 0});
  }

  // OK, we have a final resulting text. Now we compare against the input
  // to calculate a replacement map describing the changes to the input
  // necessary to get the output.
  // TODO: Document replacement map format.


  auto EmitRemapFailed = M.emitRemap();
  auto EmitMigratedFailed = M.emitMigratedFile();
  auto DumpMigrationStatesFailed = M.dumpStates();
  return EmitRemapFailed || EmitMigratedFailed || DumpMigrationStatesFailed;
}

Migrator::Migrator(CompilerInstance *StartInstance,
                   const CompilerInvocation &StartInvocation)
  : StartInstance(StartInstance), StartInvocation(StartInvocation) {

    auto ErrorOrStartBuffer = llvm::MemoryBuffer::getFile(getInputFilename());
    auto &StartBuffer = ErrorOrStartBuffer.get();
    auto StartBufferID = SrcMgr.addNewSourceBuffer(std::move(StartBuffer));
    States.push_back(MigrationState::start(SrcMgr, StartBufferID));
}

std::unique_ptr<swift::CompilerInstance>
Migrator::repeatFixitMigrations(const unsigned Iterations,
                                version::Version SwiftLanguageVersion) {
  for (unsigned i = 0; i < Iterations; ++i) {
    auto ThisInstance = performAFixItMigration(SwiftLanguageVersion);
    if (ThisInstance == nullptr) {
      break;
    } else {
      if (States.back()->noChangesOccurred()) {
        return ThisInstance;
      }
    }
  }
  return nullptr;
}

std::unique_ptr<swift::CompilerInstance>
Migrator::performAFixItMigration(version::Version SwiftLanguageVersion) {
  auto InputState = States.back();
  auto InputBuffer =
    llvm::MemoryBuffer::getMemBufferCopy(InputState->getOutputText(),
                                         getInputFilename());

  CompilerInvocation Invocation { StartInvocation };
  Invocation.clearInputs();
  Invocation.getLangOptions().EffectiveLanguageVersion = SwiftLanguageVersion;

  // SE-0160: When migrating, always use the Swift 3 @objc inference rules,
  // which drives warnings with the "@objc" Fix-Its.
  Invocation.getLangOptions().EnableSwift3ObjCInference = true;

  // The default behavior of the migrator, referred to as "minimal" migration
  // in SE-0160, only adds @objc Fix-Its to those cases where the Objective-C
  // entry point is explicitly used somewhere in the source code. The user
  // may also select a workflow that adds @objc for every declaration that
  // would infer @objc under the Swift 3 rules but would no longer infer
  // @objc in Swift 4.
  Invocation.getLangOptions().WarnSwift3ObjCInference =
    getMigratorOptions().KeepObjcVisibility
      ? Swift3ObjCInferenceWarnings::Complete
      : Swift3ObjCInferenceWarnings::Minimal;

  const auto &OrigFrontendOpts = StartInvocation.getFrontendOptions();

  auto InputBuffers = OrigFrontendOpts.InputBuffers;
  auto InputFilenames = OrigFrontendOpts.InputFilenames;

  for (const auto &Buffer : InputBuffers) {
    Invocation.addInputBuffer(Buffer);
  }

  for (const auto &Filename : InputFilenames) {
    Invocation.addInputFilename(Filename);
  }

  const unsigned PrimaryIndex =
    Invocation.getFrontendOptions().InputBuffers.size();

  Invocation.addInputBuffer(InputBuffer.get());
  Invocation.getFrontendOptions().PrimaryInput = {
    PrimaryIndex, SelectedInput::InputKind::Buffer
  };

  auto Instance = llvm::make_unique<swift::CompilerInstance>();
  if (Instance->setup(Invocation)) {
    return nullptr;
  }

  FixitApplyDiagnosticConsumer FixitApplyConsumer {
    InputState->getOutputText(),
    getInputFilename(),
  };
  Instance->addDiagnosticConsumer(&FixitApplyConsumer);

  Instance->performSema();

  StringRef ResultText = InputState->getOutputText();
  unsigned ResultBufferID = InputState->getOutputBufferID();

  if (FixitApplyConsumer.getNumFixitsApplied() > 0) {
    SmallString<4096> Scratch;
    llvm::raw_svector_ostream OS(Scratch);
    FixitApplyConsumer.printResult(OS);
    auto ResultBuffer = llvm::MemoryBuffer::getMemBufferCopy(OS.str());
    ResultText = ResultBuffer->getBuffer();
    ResultBufferID = SrcMgr.addNewSourceBuffer(std::move(ResultBuffer));
  }

  States.push_back(MigrationState::make(MigrationKind::CompilerFixits,
                                        SrcMgr, InputState->getOutputBufferID(),
                                        ResultBufferID));
  return Instance;
}

bool Migrator::performSyntacticPasses() {
  clang::FileSystemOptions ClangFileSystemOptions;
  clang::FileManager ClangFileManager { ClangFileSystemOptions };

  llvm::IntrusiveRefCntPtr<clang::DiagnosticIDs> DummyClangDiagIDs {
    new clang::DiagnosticIDs()
  };
  auto ClangDiags =
    llvm::make_unique<clang::DiagnosticsEngine>(DummyClangDiagIDs,
                                                new clang::DiagnosticOptions,
                                                new clang::DiagnosticConsumer(),
                                                /*ShouldOwnClient=*/true);

  clang::SourceManager ClangSourceManager { *ClangDiags, ClangFileManager };
  clang::LangOptions ClangLangOpts;
  clang::edit::EditedSource Edits { ClangSourceManager, ClangLangOpts };

  auto InputState = States.back();
  auto InputText = InputState->getOutputText();

  EditorAdapter Editor { StartInstance->getSourceMgr(), ClangSourceManager };

  runAPIDiffMigratorPass(Editor, StartInstance->getPrimarySourceFile(),
                         getMigratorOptions());
  runTupleSplatMigratorPass(Editor, StartInstance->getPrimarySourceFile(),
                            getMigratorOptions());
  runTypeOfMigratorPass(Editor, StartInstance->getPrimarySourceFile(),
                        getMigratorOptions());

  Edits.commit(Editor.getEdits());

  RewriteBufferEditsReceiver Rewriter {
    ClangSourceManager,
    Editor.getClangFileIDForSwiftBufferID(
      StartInstance->getPrimarySourceFile()->getBufferID().getValue()),
    InputState->getOutputText()
  };

  Edits.applyRewrites(Rewriter);

  SmallString<1024> Scratch;
  llvm::raw_svector_ostream OS(Scratch);
  Rewriter.printResult(OS);
  auto ResultBuffer = this->SrcMgr.addMemBufferCopy(OS.str());

  States.push_back(
    MigrationState::make(MigrationKind::Syntactic,
                         this->SrcMgr,
                         States.back()->getInputBufferID(),
                         ResultBuffer));
  return false;
}

bool Migrator::emitRemap() const {
  // TODO: Need to integrate diffing library to diff start and end state's
  // output text.
  return false;
}

bool Migrator::emitMigratedFile() const {
  const auto &OutFilename = getMigratorOptions().EmitMigratedFilePath;
  if (OutFilename.empty()) {
    return false;
  }

  std::error_code Error;
  llvm::raw_fd_ostream FileOS(OutFilename,
                              Error, llvm::sys::fs::F_Text);
  if (FileOS.has_error()) {
    return true;
  }

  FileOS << States.back()->getOutputText();

  FileOS.flush();

  return FileOS.has_error();
}

bool Migrator::dumpStates() const {
  const auto &OutDir = getMigratorOptions().DumpMigrationStatesDir;
  if (OutDir.empty()) {
    return false;
  }

  auto Failed = false;
  for (size_t i = 0; i < States.size(); ++i) {
    Failed |= States[i]->print(i, OutDir);
  }

  return Failed;
}

const MigratorOptions &Migrator::getMigratorOptions() const {
  return StartInvocation.getMigratorOptions();
}

const StringRef Migrator::getInputFilename() const {
  auto PrimaryInput =
    StartInvocation.getFrontendOptions().PrimaryInput.getValue();
  return StartInvocation.getInputFilenames()[PrimaryInput.Index];
}
