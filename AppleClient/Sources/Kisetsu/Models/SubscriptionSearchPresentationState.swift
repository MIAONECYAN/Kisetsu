struct SubscriptionSearchPresentationState: Equatable {
  enum PresentationPhase: Equatable {
    case closed
    case opening(Int)
    case open(Int)
    case closing(Int)
  }

  enum EscapeAction: Equatable {
    case clearedQuery
    case dismissedPopover
    case ignored
  }

  var query: String
  private(set) var phase: PresentationPhase
  private(set) var requestID: Int

  init(query: String = "", isPresented: Bool = false) {
    self.query = query
    requestID = isPresented ? 1 : 0
    phase = isPresented ? .open(1) : .closed
  }

  var isActive: Bool {
    !SubscriptionSearch.normalizedTokens(query).isEmpty
  }

  var isPresented: Bool {
    switch phase {
    case .opening, .open:
      true
    case .closed, .closing:
      false
    }
  }

  var presentationID: Int? {
    switch phase {
    case let .opening(id), let .open(id):
      id
    case .closed, .closing:
      nil
    }
  }

  var closingRequestID: Int? {
    guard case let .closing(id) = phase else { return nil }
    return id
  }

  mutating func requestPresentation() -> Int? {
    switch phase {
    case .opening, .open:
      return nil
    case .closed, .closing:
      requestID &+= 1
      phase = .opening(requestID)
      return requestID
    }
  }

  @discardableResult
  mutating func confirmPresentation(_ id: Int) -> Bool {
    guard phase == .opening(id) else { return false }
    phase = .open(id)
    return true
  }

  mutating func requestDismissal() -> Int? {
    switch phase {
    case .closed, .closing:
      return nil
    case .opening, .open:
      requestID &+= 1
      phase = .closing(requestID)
      return requestID
    }
  }

  @discardableResult
  mutating func completeDismissal(_ id: Int) -> Bool {
    guard phase == .closing(id) else { return false }
    phase = .closed
    return true
  }

  mutating func present() {
    _ = requestPresentation()
  }

  mutating func dismiss() {
    guard let id = requestDismissal() else { return }
    _ = completeDismissal(id)
  }

  mutating func forceDismiss() {
    requestID &+= 1
    phase = .closed
  }

  mutating func clear() {
    query = ""
  }

  @discardableResult
  mutating func handleEscape() -> EscapeAction {
    if isActive {
      clear()
      return .clearedQuery
    }
    if isPresented {
      _ = requestDismissal()
      return .dismissedPopover
    }
    return .ignored
  }
}
