import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct SignInFlow: View {
    enum Step: Equatable {
        case choose
        case link(ServerEndpoint, found: Bool)
        case password(ServerEndpoint, found: Bool)
    }

    @Environment(AppModel.self) private var model
    @State private var step = Step.choose

    var body: some View {
        switch step {
        case .choose: ChooseServerView { step = .link($0, found: $1) }
        case .link(let server, let found):
            LinkView(link: DeviceLinkModel(app: model, server: server)) {
                step = .password(server, found: found)
            } back: {
                step = .choose
            }
            .id(server)
        case .password(let server, let found):
            PasswordView(server: server, found: found) {
                step = .link($0, found: $0 == server && found)
            } back: {
                step = .choose
            }
        }
    }
}

struct ChooseServerView: View {
    @Environment(AppModel.self) private var model
    let chosen: (ServerEndpoint, Bool) -> Void
    @State private var discovery = ServerDiscovery()
    @State private var typing = false
    @State private var address = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        AccountPage(name: AppModel.productName) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose your server").font(.system(size: 80, weight: .bold))
                Text(subtitle).font(.system(size: 30)).foregroundStyle(Theme.secondary).padding(.top, 20)
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(discovery.servers, id: \.self) { server in
                        Button {
                            chosen(server.endpoint, true)
                        } label: {
                            ServerRow(name: server.name, detail: "\(server.address) · on this network")
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                    if typing {
                        TextField("Server address", text: $address, prompt: Text("media.example.com"))
                            .accessibilityLabel("Server address")
                            .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .focused($fieldFocused).onSubmit(submit).font(.system(size: 32)).frame(width: 948)
                    }
                    if let error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber) }
                }
                .frame(width: 948, alignment: .leading)
                .padding(.top, 44)
                HStack(spacing: 28) {
                    Button("Enter an address") {
                        typing = true
                        fieldFocused = true
                    }
                    Button("Search again") { discovery.restart() }
                }
                .buttonStyle(TVButtonStyle())
                .padding(.top, 44)
            }
            .padding(.leading, 120).padding(.top, 120)
        }
        .onAppear { if address.isEmpty { address = model.lastServer } }
        .task { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var subtitle: String {
        if !discovery.servers.isEmpty { return "Rabbit Ears servers found on this network." }
        if discovery.available == false {
            return "This Apple TV can't search the network. Enter your server's address."
        }
        return "Searching this network for Rabbit Ears servers."
    }

    private func submit() {
        guard let server = ServerEndpoint(userInput: address) else {
            error = AppError.badServer.localizedDescription
            return
        }
        chosen(server, false)
    }
}

struct ServerRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 34) {
            RabbitEarsMark().stroke(Theme.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 40, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 36, weight: .bold))
                Text(detail).font(.system(size: 28)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .frame(width: 948, height: 126)
        .background(Theme.control, in: .rect(cornerRadius: 20))
    }
}

struct LinkView: View {
    @Environment(AppModel.self) private var model
    @State private var link: DeviceLinkModel
    @State private var attempt = 0
    let password: () -> Void
    let back: () -> Void

    init(link: DeviceLinkModel, password: @escaping () -> Void, back: @escaping () -> Void) {
        _link = State(initialValue: link)
        self.password = password
        self.back = back
    }

    var body: some View {
        AccountPage(name: model.serverName(at: link.server)) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Link this Apple TV").font(.system(size: 80, weight: .bold))
                    VStack(alignment: .leading, spacing: 30) {
                        step(1, Text("Scan the code, or open \(Text(link.address).bold().foregroundColor(.white))"))
                        step(2, Text("Sign in as an adult in your household"))
                        step(3, Text("Enter this code"))
                    }
                    .padding(.top, 50)
                    code.padding(.leading, 76).padding(.top, 36)
                }
                .padding(.leading, 120).padding(.top, 80)
                Spacer(minLength: 40)
                qr.padding(.top, 107).padding(.trailing, 120)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status(at: context.date)).font(.system(size: 26)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Get a new code") { attempt += 1 }
                Button("Sign in with a password instead", action: password)
            }
            .buttonStyle(TVButtonStyle())
        }
        .task(id: attempt) { await link.run() }
        .onExitCommand(perform: back)
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(spacing: 24) {
            Text("\(number)").font(.system(size: 30, weight: .bold)).frame(width: 52, height: 52)
                .background(Theme.control, in: .circle)
            text.font(.system(size: 34)).foregroundStyle(Theme.synopsis)
        }
    }

    @ViewBuilder
    private var code: some View {
        if let code = link.link?.code {
            let parts = code.split(separator: "-", maxSplits: 1).map(String.init)
            HStack(spacing: 18) {
                Text(parts.first ?? code)
                if parts.count == 2 {
                    Capsule().fill(Theme.amber).frame(width: 42, height: 14)
                    Text(parts[1])
                }
            }
            .font(.system(size: 128, weight: .bold)).kerning(12).foregroundStyle(Theme.light)
            .accessibilityElement().accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
        } else if link.state == .starting {
            ProgressView().frame(height: 150)
        }
    }

    private var qr: some View {
        AsyncImage(url: link.qrURL) { image in
            image.resizable().interpolation(.none).scaledToFit()
        } placeholder: {
            Color.clear
        }
        .padding(26)
        .frame(width: 440, height: 440)
        .background(.white, in: .rect(cornerRadius: 24))
        .opacity(link.state == .waiting ? 1 : 0.2)
        .accessibilityLabel("QR code to link this Apple TV")
    }

    private func status(at now: Date) -> String {
        switch link.state {
        case .starting: "Getting a code."
        case .waiting:
            link.countdown(at: now).map { "Waiting for approval. This code expires in \($0)." } ?? "This code expired."
        case .expired: "This code expired."
        case .denied: "This code was turned down."
        case .failed(let message): message
        }
    }
}

struct PasswordView: View {
    @Environment(AppModel.self) private var model
    let found: Bool
    let useCode: (ServerEndpoint) -> Void
    let back: () -> Void
    @State private var server: String
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    init(
        server: ServerEndpoint, found: Bool, useCode: @escaping (ServerEndpoint) -> Void, back: @escaping () -> Void
    ) {
        _server = State(initialValue: server.baseURL.absoluteString)
        self.found = found
        self.useCode = useCode
        self.back = back
    }

    var body: some View {
        AccountPage(name: model.serverName(at: server)) {
            HStack(alignment: .top, spacing: 112) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Sign in to \(model.serverName(at: server))").font(.system(size: 80, weight: .bold))
                        .lineLimit(1).padding(.bottom, 12)
                    FormField(label: "Server", trailing: found ? "Found on your network" : nil) {
                        TextField("Server", text: $server).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    FormField(label: "Email") {
                        TextField("Email", text: $email, prompt: Text("Enter your email")).textContentType(.username)
                            .accessibilityLabel("Email")
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    FormField(label: "Password") {
                        SecureField("Password", text: $password, prompt: Text("Enter your password"))
                            .accessibilityLabel("Password")
                            .textContentType(.password).onSubmit(submit)
                    }
                    if let error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber) }
                    HStack(spacing: 28) {
                        Button(action: submit) {
                            if busy { ProgressView().tint(Theme.ground) } else { Text("Sign in") }
                        }
                        .buttonStyle(TVButtonStyle(primary: true))
                        .disabled(busy)
                        Button("Use a code instead") {
                            guard let endpoint = ServerEndpoint(userInput: server) else {
                                error = AppError.badServer.localizedDescription
                                return
                            }
                            useCode(endpoint)
                        }
                        .buttonStyle(TVButtonStyle())
                    }
                    .padding(.top, 16)
                }
                .frame(width: 820)
                VStack(alignment: .leading, spacing: 20) {
                    Text("Easier than the remote").font(.system(size: 30, weight: .bold))
                    Text("A nearby iPhone offers its keyboard and saved passwords.").font(.system(size: 28))
                        .foregroundStyle(Theme.synopsis)
                }
                .padding(40)
                .frame(width: 588, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: 24))
                .padding(.top, 154)
            }
            .padding(.leading, 120).padding(.top, 80)
        }
        .onExitCommand(perform: back)
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.signIn(server: server, email: email, password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct FormField<Field: View>: View {
    let label: String
    var trailing: String?
    @ViewBuilder var field: Field
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 24)).opacity(0.7)
                field.focused($focused).font(.system(size: 32, weight: .semibold)).textFieldStyle(.plain)
            }
            Spacer(minLength: 20)
            if let trailing { Text(trailing).font(.system(size: 24)).opacity(0.7) }
        }
        .foregroundStyle(focused ? Theme.ground : Theme.light)
        .padding(.horizontal, 28)
        .frame(height: 104)
        .background(focused ? Theme.light : Theme.control, in: .rect(cornerRadius: 16))
        .scaleEffect(focused ? 1.03 : 1)
        .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: 30, y: 26)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}
