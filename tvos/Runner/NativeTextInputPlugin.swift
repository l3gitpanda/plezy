import UIKit

#if os(tvOS)
  import Flutter

  final class NativeTextInputPlugin: NSObject, FlutterPlugin {
    private static let channelName = "com.plezy/native_keyboard"

    private let channel: FlutterMethodChannel
    private lazy var textField: UITextField = makeTextField()
    private var session: Session?
    private var justSubmitted = false

    private struct Session {
      let requestId: Int
      let maxLength: Int?
    }

    static func register(with registrar: FlutterPluginRegistrar) {
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
      let instance = NativeTextInputPlugin(channel: channel)
      registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private init(channel: FlutterMethodChannel) {
      self.channel = channel
      super.init()
    }

    private func makeTextField() -> UITextField {
      let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      field.alpha = 0.01
      field.isUserInteractionEnabled = false
      field.delegate = self
      field.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
      return field
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard let args = call.arguments as? [String: Any], let requestId = args["requestId"] as? Int else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing requestId", details: nil))
        return
      }
      switch call.method {
      case "show": handleShow(requestId: requestId, args: args, result: result)
      case "update": handleUpdate(requestId: requestId, args: args, result: result)
      case "dismiss": handleDismiss(requestId: requestId, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }

    private func handleShow(requestId: Int, args: [String: Any], result: @escaping FlutterResult) {
      guard let hostView = resolveHostView() else {
        result(FlutterError(code: "NO_HOST_VIEW", message: "No root view available", details: nil))
        return
      }
      if textField.superview == nil {
        hostView.addSubview(textField)
      }
      if let previous = session, previous.requestId != requestId {
        channel.invokeMethod("closed", arguments: ["requestId": previous.requestId])
      }

      session = Session(requestId: requestId, maxLength: args["maxLength"] as? Int)
      justSubmitted = false
      configure(textField, with: args)
      textField.text = args["text"] as? String ?? ""
      result(nil)

      DispatchQueue.main.async { [weak self] in
        guard let self, self.session?.requestId == requestId else { return }
        self.textField.becomeFirstResponder()
      }
    }

    private func handleUpdate(requestId: Int, args: [String: Any], result: @escaping FlutterResult) {
      guard session?.requestId == requestId else {
        result(nil)
        return
      }
      textField.text = args["text"] as? String ?? textField.text
      result(nil)
    }

    private func handleDismiss(requestId: Int, result: @escaping FlutterResult) {
      guard session?.requestId == requestId else {
        result(nil)
        return
      }
      if textField.isFirstResponder {
        textField.resignFirstResponder()
      } else {
        // The deferred `becomeFirstResponder` queued by `handleShow` may not have
        // run yet (GCD FIFO can order a same-requestId dismiss ahead of it).
        // Resigning a field that never became first responder is a no-op and
        // `textFieldDidEndEditing` would not fire, so clear the session here
        // directly instead — otherwise that deferred block would later present
        // a keyboard for a session Dart has already torn down.
        channel.invokeMethod("closed", arguments: ["requestId": requestId])
        session = nil
      }
      result(nil)
    }

    private func configure(_ field: UITextField, with args: [String: Any]) {
      field.keyboardType = Self.keyboardType(for: args["keyboardType"] as? String)
      field.isSecureTextEntry = args["obscureText"] as? Bool ?? false
      field.returnKeyType = Self.returnKeyType(for: args["textInputAction"] as? String)
      field.autocorrectionType = (args["autocorrect"] as? Bool ?? true) ? .yes : .no
      field.autocapitalizationType = Self.autocapitalization(for: args["textCapitalization"] as? String)
      field.placeholder = args["hintText"] as? String
    }

    @objc private func textDidChange() {
      guard let session else { return }
      channel.invokeMethod("textChanged", arguments: ["requestId": session.requestId, "text": textField.text ?? ""])
    }

    private func resolveHostView() -> UIView? {
      resolveRootViewController()?.view
    }

    private func resolveRootViewController() -> UIViewController? {
      if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let window = windowScene.windows.first
      {
        return window.rootViewController
      }
      return UIApplication.shared.windows.first?.rootViewController
    }

    private static func keyboardType(for name: String?) -> UIKeyboardType {
      switch name {
      case "number": return .numberPad
      case "phone": return .phonePad
      case "email": return .emailAddress
      case "url": return .URL
      default: return .default
      }
    }

    private static func returnKeyType(for action: String?) -> UIReturnKeyType {
      switch action {
      case "search": return .search
      case "next": return .next
      case "go": return .go
      case "send": return .send
      case "done": return .done
      default: return .default
      }
    }

    private static func autocapitalization(for name: String?) -> UITextAutocapitalizationType {
      switch name {
      case "words": return .words
      case "sentences": return .sentences
      case "characters": return .allCharacters
      default: return .none
      }
    }
  }

  extension NativeTextInputPlugin: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      guard let session else { return true }
      justSubmitted = true
      channel.invokeMethod("submitted", arguments: ["requestId": session.requestId, "text": textField.text ?? ""])
      textField.resignFirstResponder()
      return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      guard let session else { return }
      if !justSubmitted {
        channel.invokeMethod("closed", arguments: ["requestId": session.requestId])
      }
      justSubmitted = false
      self.session = nil
      resolveRootViewController()?.becomeFirstResponder()
    }

    func textField(
      _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
    ) -> Bool {
      guard let maxLength = session?.maxLength, maxLength > 0 else { return true }
      let current = textField.text ?? ""
      guard let stringRange = Range(range, in: current) else { return true }
      return current.replacingCharacters(in: stringRange, with: string).count <= maxLength
    }
  }
#endif
