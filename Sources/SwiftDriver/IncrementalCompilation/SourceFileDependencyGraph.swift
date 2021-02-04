//===---SourceFileDependencyGraph.swift - Read swiftdeps or swiftmodule files ---===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Foundation
import TSCBasic
import TSCUtility

/*@_spi(Testing)*/ public struct SourceFileDependencyGraph {
  public static let sourceFileProvidesInterfaceSequenceNumber: Int = 0
  public static let sourceFileProvidesImplementationSequenceNumber: Int = 1
  
  public var majorVersion: UInt64
  public var minorVersion: UInt64
  public var compilerVersionString: String
  private var allNodes: [Node]
  
  public var sourceFileNodePair: (interface: Node, implementation: Node) {
    (interface: allNodes[SourceFileDependencyGraph.sourceFileProvidesInterfaceSequenceNumber],
     implementation: allNodes[SourceFileDependencyGraph.sourceFileProvidesImplementationSequenceNumber])
  }
  
  public func forEachNode(_ doIt: (Node) -> Void) {
    allNodes.forEach(doIt)
  }
  
  public func forEachDefDependedUpon(by node: Node, _ doIt: (Node) -> Void) {
    for sequenceNumber in node.defsIDependUpon {
      doIt(allNodes[sequenceNumber])
    }
  }
  
  public func forEachArc(_ doIt: (Node, Node) -> Void) {
    forEachNode { useNode in
      forEachDefDependedUpon(by: useNode) { defNode in
        doIt(defNode, useNode)
      }
    }
  }
  
  @discardableResult public func verify() -> Bool {
    assert(Array(allNodes.indices) == allNodes.map { $0.sequenceNumber })
    forEachNode {
      $0.verify()
    }
    return true
  }
}

// TODO: move somewhere
protocol CanHoldExternalDependency {
  var key: DependencyKey {get}
  var fingerprint: String? {get}
}
extension CanHoldExternalDependency {
  func verifyExternalInvariant() throws {
    guard case .externalDepend(let externalDependency) = key.designator
    else {
      return
    }
    guard key.aspect == .interface else {
      throw CanHoldExternalDependencyError.externalDepsMustBeInterface(externalDependency)
    }
    guard let file = externalDependency.file else {
      throw CanHoldExternalDependencyError.noFile(externalDependency)
    }
    guard let fingerprint = self.fingerprint,
          file.extension == FileType.swiftModule.rawValue
    else {
      return
    }
    throw CanHoldExternalDependencyError.onlySwiftModulesHaveFingerprints(externalDependency, fingerprint)
  }
}
enum CanHoldExternalDependencyError: LocalizedError {
  case externalDepsMustBeInterface(ExternalDependency)
  case noFile(ExternalDependency)
  case onlySwiftModulesHaveFingerprints(ExternalDependency, String)

  var errorDescription: String? {
    switch self {
    case let .externalDepsMustBeInterface(externalDependency):
      return "Aspect of external dependency must be interface: \(externalDependency)"
    case let .noFile(externalDependency):
      return "External dependency must point to a file: \(externalDependency)"
    case let .onlySwiftModulesHaveFingerprints(externalDependency, fingerprint):
      return "An external dependency with a fingerprint (\(fingerprint)) must point to a swiftmodule file: \(externalDependency)"
    }
  }
}



extension SourceFileDependencyGraph {
  public struct Node: CanHoldExternalDependency {
    public var key: DependencyKey
    public var fingerprint: String?
    public var sequenceNumber: Int
    public var defsIDependUpon: [Int]
    public var isProvides: Bool
    
    /*@_spi(Testing)*/ public init(
      key: DependencyKey,
      fingerprint: String?,
      sequenceNumber: Int,
      defsIDependUpon: [Int],
      isProvides: Bool
    ) {
      self.key = key
      self.fingerprint = fingerprint
      self.sequenceNumber = sequenceNumber
      self.defsIDependUpon = defsIDependUpon
      self.isProvides = isProvides

      #warning("how best to handle an error here")
      try! verifyExternalInvariant()
    }
    
    public func verify() {
      key.verify()
      
      if case .sourceFileProvide = key.designator {
        switch key.aspect {
        case .interface:
          assert(sequenceNumber == SourceFileDependencyGraph.sourceFileProvidesInterfaceSequenceNumber)
        case .implementation:
          assert(sequenceNumber == SourceFileDependencyGraph.sourceFileProvidesImplementationSequenceNumber)
        }
      }
    }

    public var isIncrementalExternalDependency: Bool {
      if case .externalDepend = key.designator,
         fingerprint != nil {
        return true
      }
      return false
    }
  }
}

extension SourceFileDependencyGraph {
  private enum RecordKind: UInt64 {
    case metadata = 1
    case sourceFileDepGraphNode
    case fingerprintNode
    case dependsOnDefinitionNode
    case identifierNode
  }
  
  fileprivate enum ReadError: Error {
    case badMagic
    case swiftModuleHasNoDependencies
    case noRecordBlock
    case malformedMetadataRecord
    case unexpectedMetadataRecord
    case malformedFingerprintRecord
    case malformedDependsOnDefinitionRecord
    case malformedIdentifierRecord
    case malformedSourceFileDepGraphNodeRecord
    case unknownRecord
    case unexpectedSubblock
    case bogusNameOrContext
    case unknownKind
  }

  /// Returns nil if there was no dependency info
  static func read(
    from dependencySource: ModuleDependencyGraph.DependencySource,
    on fileSystem: FileSystem
  ) throws -> Self? {
    try self.init(contentsOf: dependencySource.typedFile, on: fileSystem)
  }
  
  /*@_spi(Testing)*/ public init(nodesForTesting: [Node]) {
    majorVersion = 0
    minorVersion = 0
    compilerVersionString = ""
    allNodes = nodesForTesting
  }

  /*@_spi(Testing)*/ public init?(
    contentsOf path: TypedVirtualPath,
    on filesystem: FileSystem
  ) throws {
    let data = try filesystem.readFileContents(path.file)
    try self.init(data: data, fromSwiftModule: path.type == .swiftModule)
  }

  /// Returns nil for a swiftmodule with no depenencies
  /*@_spi(Testing)*/ public init?(
    data: ByteString,
    fromSwiftModule extractFromSwiftModule: Bool = false
  ) throws {
    struct Visitor: BitstreamVisitor {
      let extractFromSwiftModule: Bool

      init(extractFromSwiftModule: Bool) {
        self.extractFromSwiftModule = extractFromSwiftModule
      }

      var nodes: [Node] = []
      var majorVersion: UInt64?
      var minorVersion: UInt64?
      var compilerVersionString: String?

      private var node: Node? = nil
      private var identifiers: [String] = [""] // The empty string is hardcoded as identifiers[0]
      private var sequenceNumber = 0

      func validate(signature: Bitcode.Signature) throws {
        if extractFromSwiftModule {
          guard signature == .init(value: 0x0EA89CE2) else { throw ReadError.swiftModuleHasNoDependencies }
        } else {
          guard signature == .init(string: "DEPS") else { throw ReadError.badMagic }
        }
      }

      mutating func shouldEnterBlock(id: UInt64) throws -> Bool {
        if extractFromSwiftModule {
          // Enter the top-level module block, and the incremental info
          // subblock, ignoring the rest of the file.
          return id == /*Module block*/ 8 || id == /*Incremental record block*/ 196
        } else {
          guard id == /*Incremental record block*/ 8 else {
            throw ReadError.unexpectedSubblock
          }
          return true
        }
      }

      mutating func didExitBlock() throws {
        // Finalize the current node if needed.
        if let node = node {
          nodes.append(node)
          self.node = nil
        }
      }

      mutating func visit(record: BitcodeElement.Record) throws {
        guard let kind = RecordKind(rawValue: record.id) else { throw ReadError.unknownRecord }
        switch kind {
        case .metadata:
          // If we've already read metadata, this is an unexpected duplicate.
          guard majorVersion == nil, minorVersion == nil, compilerVersionString == nil else {
            throw ReadError.unexpectedMetadataRecord
          }
          guard record.fields.count == 2,
                case .blob(let compilerVersionBlob) = record.payload,
                let compilerVersionString = String(data: compilerVersionBlob, encoding: .utf8)
          else { throw ReadError.malformedMetadataRecord }

          self.majorVersion = record.fields[0]
          self.minorVersion = record.fields[1]
          self.compilerVersionString = compilerVersionString
        case .sourceFileDepGraphNode:
          if let node = node {
            nodes.append(node)
          }
          let kindCode = record.fields[0]
          guard record.fields.count == 5,
                let declAspect = DependencyKey.DeclAspect(record.fields[1]),
                record.fields[2] < identifiers.count,
                record.fields[3] < identifiers.count else {
            throw ReadError.malformedSourceFileDepGraphNodeRecord
          }
          let context = identifiers[Int(record.fields[2])]
          let identifier = identifiers[Int(record.fields[3])]
          let isProvides = record.fields[4] != 0
          let designator = try DependencyKey.Designator(
            kindCode: kindCode, context: context, name: identifier)
          let key = DependencyKey(aspect: declAspect, designator: designator)
          node = Node(key: key,
                      fingerprint: nil,
                      sequenceNumber: sequenceNumber,
                      defsIDependUpon: [],
                      isProvides: isProvides)
          sequenceNumber += 1
        case .fingerprintNode:
          guard node != nil,
                record.fields.count == 0,
                case .blob(let fingerprintBlob) = record.payload,
                let fingerprint = String(data: fingerprintBlob, encoding: .utf8) else {
            throw ReadError.malformedFingerprintRecord
          }
          node?.fingerprint = fingerprint
        case .dependsOnDefinitionNode:
          guard node != nil,
                record.fields.count == 1 else { throw ReadError.malformedDependsOnDefinitionRecord }
          node?.defsIDependUpon.append(Int(record.fields[0]))
        case .identifierNode:
          guard record.fields.count == 0,
                case .blob(let identifierBlob) = record.payload,
                let identifier = String(data: identifierBlob, encoding: .utf8) else {
            throw ReadError.malformedIdentifierRecord
          }
          identifiers.append(identifier)
        }
      }
    }

    var visitor = Visitor(extractFromSwiftModule: extractFromSwiftModule)
    do {
      try data.contents.withUnsafeBytes { buf in
        // SAFETY: The bitcode reader does not mutate the data stream we give it.
        // FIXME: Let's avoid this altogether and traffic in ByteString/[UInt8]
        // if possible. There's no real reason to use `Data` in this API.
        let baseAddr = UnsafeMutableRawPointer(mutating: buf.baseAddress!)
        let data = Data(bytesNoCopy: baseAddr, count: buf.count, deallocator: .none)
        try Bitcode.read(stream: data, using: &visitor)
      }
    }
    catch ReadError.swiftModuleHasNoDependencies {
      return nil
    }
    guard let major = visitor.majorVersion,
          let minor = visitor.minorVersion,
          let versionString = visitor.compilerVersionString else {
      throw ReadError.malformedMetadataRecord
    }
    self.majorVersion = major
    self.minorVersion = minor
    self.compilerVersionString = versionString
    self.allNodes = visitor.nodes
  }
}

fileprivate extension DependencyKey.DeclAspect {
  init?(_ c: UInt64) {
    switch c {
    case 0: self = .interface
    case 1: self = .implementation
    default: return nil
    }
  }
}

fileprivate extension DependencyKey.Designator {
  init(kindCode: UInt64,
       context: String,
       name: String) throws {
    func mustBeEmpty(_ s: String) throws {
      guard s.isEmpty else { throw SourceFileDependencyGraph.ReadError.bogusNameOrContext }
    }
    switch kindCode {
    case 0:
      try mustBeEmpty(context)
      self = .topLevel(name: name)
    case 1:
      try mustBeEmpty(name)
      self = .nominal(context: context)
    case 2:
      try mustBeEmpty(name)
      self = .potentialMember(context: context)
    case 3:
      self = .member(context: context, name: name)
    case 4:
      try mustBeEmpty(context)
      self = .dynamicLookup(name: name)
    case 5:
      try mustBeEmpty(context)
      self = .externalDepend(ExternalDependency(name))
    case 6:
      try mustBeEmpty(context)
      self = .sourceFileProvide(name: name)
    default: throw SourceFileDependencyGraph.ReadError.unknownKind
    }
  }
}

