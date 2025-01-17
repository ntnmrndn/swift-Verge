//
// Copyright (c) 2020 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import class Foundation.NSMapTable
import class Foundation.NSString

#if canImport(Combine)
import Combine
#endif

public protocol DerivedType {
  associatedtype Value: Equatable

  func asDerived() -> Derived<Value>
}

/**
 A container object that provides the current value and changes from the source Store.

 This object does not know what the value managed by.
 In most cases, `Store` will be running underlying.

 Derived's functions are:
 - Computes the derived data from the state tree
 - Emit the updated data with updating Store
 - Supports subscribe the data
 - Supports Memoization

 Conforms to Equatable that compares pointer personality.
 */
public class Derived<Value: Equatable>: _VergeObservableObjectBase, DerivedType, @unchecked Sendable {

  /// Returns Derived object that provides constant value.
  ///
  /// - Parameter value:
  /// - Returns:
  public static func constant(_ value: Value) -> Derived<Value> {
    .init(constant: value)
  }

  #if canImport(Combine)
  @available(iOS 13, macOS 10.15, tvOS 13, watchOS 6, *)
  public final override var objectWillChange: ObservableObjectPublisher {
    innerStore.objectWillChange
  }
  #endif
  
  /// A current state.
  public var primitiveValue: Value {
    innerStore.primitiveState
  }
  
  /// A current changes state.
  public var value: Changes<Value> {
    innerStore.state
  }
  
  /// A current changes state.
  @available(*, deprecated, renamed: "value")
  public var changes: Changes<Value> {
    innerStore.state
  }
  
  let innerStore: Store<Value, Never>
  
  public var _innerStore: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(innerStore).toOpaque()
  }
      
  fileprivate let _set: ((Value) -> Void)?
  
  private let subscription: VergeAnyCancellable
  private let retainsUpstream: Any?
  private var associatedObjects: ContiguousArray<AnyObject> = .init()
  
  // MARK: - Initializers

  private init(constant: Value) {
    self.innerStore = .init(initialState: constant, logger: nil)
    self._set = { _ in }
    self.subscription = .init(onDeinit: {})
    self.retainsUpstream = nil
  }

  /// Low-level initializer
  /// - Parameters:
  ///   - get: MemoizeMap to make a `Value` from `UpstreamState`
  ///   - set: A closure to apply new-value to `UpstreamState`, it will need in creating `BindingDerived`.
  ///   - initialUpstreamState: Initial value of the `UpstreamState`
  ///   - subscribeUpstreamState: Starts subscribe updates of the `UpstreamState`
  ///   - retainsUpstream: Any instances to retain in this instance.
  public init<UpstreamState, Pipeline: PipelineType>(
    get pipeline: Pipeline,
    set: ((Pipeline.Output) -> Void)?,
    initialUpstreamState: UpstreamState,
    subscribeUpstreamState: (@escaping (UpstreamState) -> Void) -> CancellableType,
    retainsUpstream: Any?
  ) where Pipeline.Input == UpstreamState, Value == Pipeline.Output {
    
    let store = Store<Value, Never>.init(initialState: pipeline.yield(initialUpstreamState), logger: nil)
                     
    let s = subscribeUpstreamState { [weak store] value in
      let update = pipeline.yieldContinuously(value)
      switch update {
      case .noUpdates:
        break
      case .new(let newState):
        // TODO: Take over state.modification & state.mutation
        store?.commit {
          $0.replace(with: newState)
        }
      }
    }
    
    self.retainsUpstream = retainsUpstream
    self.subscription = VergeAnyCancellable.init(s)
    self._set = set
    self.innerStore = store
  }
  
  /// Low-level initializer
  /// - Parameters:
  ///   - get: MemoizeMap to make a `Value` from `UpstreamState`
  ///   - set: A closure to apply new-value to `UpstreamState`, it will need in creating `BindingDerived`.
  ///   - initialUpstreamState: Initial value of the `UpstreamState`
  ///   - subscribeUpstreamState: Starts subscribe updates of the `UpstreamState`
  ///   - retainsUpstream: Any instances to retain in this instance.
  public init<UpstreamState: HasTraces, Pipeline: PipelineType>(
    get pipeline: Pipeline,
    set: ((Pipeline.Output) -> Void)?,
    initialUpstreamState: UpstreamState,
    subscribeUpstreamState: (@escaping (UpstreamState) -> Void) -> CancellableType,
    retainsUpstream: Any?
  ) where Pipeline.Input == UpstreamState, Value == Pipeline.Output {
  
    let innerStore = Store<Value, Never>.init(initialState: pipeline.yield(initialUpstreamState), logger: nil)
        
    let pointer = Unmanaged.passUnretained(innerStore).toOpaque()
           
    let s = subscribeUpstreamState { [weak innerStore] value in
      let update = pipeline.yieldContinuously(value)
      switch update {
      case .noUpdates:
        break
      case .new(let newState):
        // TODO: Take over state.modification & state.mutation
        innerStore?.commit("Derived<InnerStore:\(pointer)>") {
          $0.append(traces: value.traces)
          $0.replace(with: newState)
        }
      }
    }
        
    self.retainsUpstream = retainsUpstream
    self.subscription = VergeAnyCancellable(s)
    self._set = set
    self.innerStore = innerStore
    
  }

  deinit {

  }
  
  // MARK: - Functions
  
  public func asDerived() -> Derived<Value> {
    self
  }
  
  public func associate(_ object: AnyObject) {
    self.associatedObjects.append(object)
  }
  
  private func _sinkValue(
    dropsFirst: Bool = false,
    queue: TargetQueueType,
    receive: @escaping (Changes<Value>) -> Void
  ) -> VergeAnyCancellable {
    innerStore._sinkState(
      dropsFirst: dropsFirst,
      queue: queue,
      receive: receive
    )
    .associate(self)
  }
  
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - dropsFirst: Drops the latest value on start. if true, receive closure will be called next time state is updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkValue(
    dropsFirst: Bool = false,
    queue: TargetQueue,
    receive: @escaping (Changes<Value>) -> Void
  ) -> VergeAnyCancellable {
    innerStore.sinkState(
      dropsFirst: dropsFirst,
      queue: queue,
      receive: receive
    )
    .associate(self)
  }
  
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - dropsFirst: Drops the latest value on start. if true, receive closure will be called next time state is updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkValue(
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Changes<Value>) -> Void
  ) -> VergeAnyCancellable {
    innerStore.sinkState(
      dropsFirst: dropsFirst,
      queue: queue,
      receive: receive
    )
    .associate(self)
  }

  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - scan: Accumulates a specified type of value over receiving updates.
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkValue<Accumulate>(
    scan: Scan<Changes<Value>, Accumulate>,
    dropsFirst: Bool = false,
    queue: TargetQueue,
    receive: @escaping (Changes<Value>, Accumulate) -> Void
  ) -> VergeAnyCancellable {
    innerStore.sinkState(
      scan: scan,
      dropsFirst: dropsFirst,
      queue: queue,
      receive: receive
    )
    .associate(self)
  }
  
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - scan: Accumulates a specified type of value over receiving updates.
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkValue<Accumulate>(
    scan: Scan<Changes<Value>, Accumulate>,
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Changes<Value>, Accumulate) -> Void
  ) -> VergeAnyCancellable {
    innerStore.sinkState(
      scan: scan,
      dropsFirst: dropsFirst,
      queue: queue,
      receive: receive
    )
    .associate(self)
  }
     
  /// Make a new Derived object that projects the specified shape of the object from the object itself projects.
  ///
  /// Drops output value if no changes with Equatable
  ///
  /// - Parameters:
  ///   - queue: a queue to receive object
  ///   - pipeline:
  /// - Returns: Derived object that cached depends on the specified parameters
  /// - Attention:
  ///     As possible use the same pipeline instance and queue in order to enable caching.
  ///     Returns the Derived that previously created with that combination.
  public func chain<Pipeline: PipelineType>(
    _ pipeline: Pipeline,
    queue: TargetQueueType = TargetQueue.passthrough
  ) -> Derived<Pipeline.Output> where Pipeline.Input == Changes<Value> {
    
    vergeSignpostEvent("Derived.chain.new", label: "\(type(of: Value.self)) -> \(type(of: Pipeline.Output.self))")
    
    let d = Derived<Pipeline.Output>(
//      get: .init(makeInitial: {
//        pipeline.makeInitial($0)
//      }, update: {
//        switch pipeline.makeResult($0) {
//        case .noUpdates: return .noUpdates
//        case .new(let s): return .new(s)
//        }
//      }),
      get: pipeline,
      set: { _ in },
      initialUpstreamState: value,
      subscribeUpstreamState: { callback in
        self.innerStore._sinkState(
          dropsFirst: true,
          queue: queue,
          receive: callback
        )
      },
      retainsUpstream: self
    )
    
    return d
  }
  
}

extension Derived: CustomReflectable {
  public var customMirror: Mirror {
    Mirror.init(
      self,
      children: [
        "upstream" : retainsUpstream as Any,
        "value" : value
    ],
      displayStyle: .struct,
      ancestorRepresentation: .generated
    )
  }
}

extension Derived : Equatable {
  public static func == (lhs: Derived<Value>, rhs: Derived<Value>) -> Bool {
    lhs === rhs
  }
}

extension Derived : Hashable {
  public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }
}

extension Derived where Value : Equatable {
  
  /// Subscribe the state changes
  ///
  /// Receives a value only changed
  ///
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkChangedPrimitiveValue(
    dropsFirst: Bool = false,
    queue: TargetQueue,
    receive: @escaping (Value) -> Void
  ) -> VergeAnyCancellable {
    sinkValue(dropsFirst: dropsFirst, queue: queue) { (changes) in
      changes.ifChanged { value in
        receive(value)
      }
    }
  }

  /// Subscribe the state changes
  ///
  /// Receives a value only changed
  ///
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkChangedPrimitiveValue(
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Value) -> Void
  ) -> VergeAnyCancellable {
    sinkValue(dropsFirst: dropsFirst, queue: queue) { (changes) in
      changes.ifChanged { value in
        receive(value)
      }
    }
  }
  
}

// `Value == Never` eliminates specializing requirements.
extension Derived where Value == Never {
    
  /// Make Derived that projects combined value from specified source Derived objects.
  ///
  /// It retains specified Derived objects as data source until itself deallocated
  ///
  /// - Parameters:
  ///   - s0:
  ///   - s1:
  /// - Returns:
  public static func combined<S0, S1>(
    _ s0: Derived<S0>,
    _ s1: Derived<S1>,
    queue: TargetQueueType = .passthrough
  ) -> Derived<Edge<(Changes<S0>, Changes<S1>)>> {
        
    let initial = Changes.init(old: nil, new: Edge(wrappedValue: (s0.value, s1.value)))
    
    let buffer = VergeConcurrency.RecursiveLockAtomic.init(initial)
        
    return Derived<Edge<(Changes<S0>, Changes<S1>)>>(
      get: .map(\.root),
      set: { _ in },
      initialUpstreamState: initial,
      subscribeUpstreamState: { callback in
                
        let _s0 = s0._sinkValue(dropsFirst: true, queue: queue) { (s0) in
          buffer.modify { value in
            let newValue = value.makeNextChanges(
              with: value.primitive.next((s0, value.primitive.1)),
              from: [],
              modification: .indeterminate
            )
            value = newValue
            callback(newValue)
          }
        }

        let _s1 = s1._sinkValue(dropsFirst: true, queue: queue) { (s1) in
          buffer.modify { value in

            let newValue = value.makeNextChanges(
              with: value.primitive.next((value.primitive.0, s1)),
              from: [],
              modification: .indeterminate
            )
            value = newValue
            callback(newValue)
          }
        }

        return VergeAnyCancellable(onDeinit: {
          _s0.cancel()
          _s1.cancel()
        })
        
    },
      retainsUpstream: [s0, s1]
    )
    
  }
    
  /// Make Derived that projects combined value from specified source Derived objects.
  ///
  /// It retains specified Derived objects as data source until itself deallocated
  ///
  /// - Parameters:
  ///   - s0:
  ///   - s1:
  ///   - s2:
  /// - Returns:
  public static func combined<S0, S1, S2>(
    _ s0: Derived<S0>,
    _ s1: Derived<S1>,
    _ s2: Derived<S2>,
    queue: TargetQueueType = .passthrough
  ) -> Derived<Edge<(Changes<S0>, Changes<S1>, Changes<S2>)>> {
        
    let initial = Changes.init(old: nil, new: Edge(wrappedValue: (s0.value, s1.value, s2.value)))
    
    let buffer = VergeConcurrency.RecursiveLockAtomic.init(initial)
    
    return Derived<Edge<(Changes<S0>, Changes<S1>, Changes<S2>)>>(
      get: .map(\.root),
      set: { _ in },
      initialUpstreamState: initial,
      subscribeUpstreamState: { callback in
        
        let _s0 = s0._sinkValue(dropsFirst: true, queue: queue) { (s0) in
          buffer.modify { value in
            let newValue = value.makeNextChanges(
              with: value.primitive.next((s0, value.primitive.1, value.primitive.2)),
              from: [],
              modification: .indeterminate
            )
            value = newValue
            callback(newValue)
          }
        }
        
        let _s1 = s1._sinkValue(dropsFirst: true, queue: queue) { (s1) in
          buffer.modify { value in
            
            let newValue = value.makeNextChanges(
              with: value.primitive.next((value.primitive.0, s1, value.primitive.2)),
              from: [],
              modification: .indeterminate
            )
            value = newValue
            callback(newValue)
          }
        }
        
        let _s2 = s2._sinkValue(dropsFirst: true, queue: queue) { (s2) in
          buffer.modify { value in
            
            let newValue = value.makeNextChanges(
              with: value.primitive.next((value.primitive.0, value.primitive.1, s2)),
              from: [],
              modification: .indeterminate
            )
            value = newValue
            callback(newValue)
          }
        }
        
        return VergeAnyCancellable(onDeinit: {
          _s0.cancel()
          _s1.cancel()
          _s2.cancel()
        })
        
      },
      retainsUpstream: [s0, s1, s2]
    )
    
  }
  
}

/**
 A Derived object that can set a value.
 By setting value, it forwards that value underlying the state store that providing value.
 This object does not know what the value managed by.
 In most cases, `Store` will be running underlying.
 */
@propertyWrapper
public final class BindingDerived<Value: Equatable>: Derived<Value> {
  
  /**
   Returns a derived value that created by get-pipeline.
   And can modify the value.
   
   - Warning: It does not always return the latest value after set a new value. It depends the specified target-queue.
   */
  public override var primitiveValue: Value {
    get { innerStore.primitiveState }
    set {
      guard let set = _set else {
        assertionFailure("Setter closure is unset. NewValue won't be applied. \(newValue)")
        return
      }
      set(newValue)
    }
  }

  /**
   Returns a derived value that created by get-pipeline.
   And can modify the value.
   
   - Warning: It does not always return the latest value after set a new value. It depends the specified target-queue.
   */
  public var wrappedValue: Value {
    get { primitiveValue }
    set { primitiveValue = newValue }
  }
  
  public var projectedValue: BindingDerived<Value> {
    self
  }

}
