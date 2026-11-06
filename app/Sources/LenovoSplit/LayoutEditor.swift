import SwiftUI
import DisplayLayout

struct LayoutEditor: View {
    @ObservedObject var model: Model
    @State private var draft: ScreenLayout
    @State private var names: [String]
    @State private var dragging: String?
    @State private var dragOffset: CGSize = .zero
    @State private var message = ""

    init(model: Model) {
        self.model = model
        _draft = State(initialValue: model.controller.layout ?? ScreenLayout.defaultLayout(sizes: model.controller.layoutSizes))
        _names = State(initialValue: model.panelNames)
    }
    private var sizes: [ScreenSize] { model.controller.layoutSizes }
    private func number(_ key: String) -> Int { key == "builtin" ? 3 : (key == "panel1" ? 1 : 2) }
    private func label(_ key: String) -> String { key == "builtin" ? "Mac display" : names[number(key)-1] }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    Text("Arrange displays").font(.title2.bold())
                    Text("Drag each screen to match your desk. Edges snap together.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Identify") { model.identifyDisplays() }.disabled(!model.running)
            }
            canvas.frame(height: 260).background(.quaternary.opacity(0.35),in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            HStack(spacing: 16) {
                ForEach(0..<2,id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text("Display \(i+1)").font(.caption).foregroundStyle(.secondary)
                        TextField("Display \(i+1)",text: $names[i]).textFieldStyle(.roundedBorder)
                    }
                }
                Button("Save names") { model.savePanelNames(names); message = "Names saved. macOS will use them after the next reconnect." }
            }
            Toggle("Swap which physical monitor shows display 1 and 2",isOn: $model.swap)
                .disabled(model.previewSeconds > 0 || !model.running)
            Text("Use Identify to match the numbers to your monitors. Names are labels you choose; the dock may hide each monitor’s own name.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
            if !message.isEmpty { Text(message).font(.callout).fixedSize(horizontal: false,vertical: true) }
            if let error = draft.validationError(sizes: sizes), model.running { Text(error).foregroundStyle(.orange) }
            if !model.running { Text("Connect both monitors and start the screens to arrange them.").foregroundStyle(.secondary) }
            HStack {
                Button("Reset layout") { draft = .defaultLayout(sizes: sizes) }.disabled(model.previewSeconds > 0)
                Spacer()
                if model.previewSeconds > 0 {
                    Text("Reverts in \(model.previewSeconds)s").monospacedDigit()
                    Button("Revert") { model.revertLayout(); if let layout = model.controller.layout { draft = layout } }
                    Button("Keep layout") { model.keepLayout(); message = "Layout saved for the next connection." }
                        .keyboardShortcut(.defaultAction).disabled(!model.layoutVerified)
                } else {
                    Button("Apply layout") {
                        do { try model.previewLayout(draft); message = "Check the screens, then keep or revert this layout." }
                        catch { message = error.localizedDescription }
                    }.disabled(!model.running || draft.validationError(sizes: sizes) != nil)
                }
            }
        }.padding(24).frame(width: 620)
            .onChange(of: model.running) { _,running in
                if running,let layout = model.controller.layout { draft = layout }
            }
            .onChange(of: model.previewSeconds) { old,new in
                if old > 0 && new == 0,let layout = model.controller.layout {
                    draft = layout
                    if message.hasPrefix("Check the screens") { message = "Preview ended. The current layout is shown above." }
                }
            }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let bounds = sizes.map { draft.rect(for: $0) }.reduce(CGRect.null) { $0.union($1) }
            let s = bounds.isNull ? 0.1 : min((proxy.size.width-80)/max(bounds.width,1),(proxy.size.height-64)/max(bounds.height,1))
            let origin = CGPoint(x: (proxy.size.width-bounds.width*s)/2-bounds.minX*s,
                                 y: (proxy.size.height-bounds.height*s)/2-bounds.minY*s)
            ZStack(alignment: .topLeading) {
                ForEach(sizes,id: \.id) { size in
                    let rect = draft.rect(for: size)
                    let offset = dragging == size.id ? dragOffset : .zero
                    VStack(spacing: 4) {
                        Text("\(number(size.id))").font(.title2.bold())
                        Text(label(size.id)).font(.caption).lineLimit(1)
                        if size.id == "builtin" { Text("Main display").font(.system(size: 9)).opacity(0.8) }
                    }.foregroundStyle(.white)
                        .frame(width: max(40,rect.width*s),height: max(40,rect.height*s))
                        .background((size.id == "builtin" ? Color.indigo : Color.accentColor).gradient,in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5)))
                        .position(x: origin.x+rect.midX*s+offset.width,y: origin.y+rect.midY*s+offset.height)
                        .accessibilityLabel("Display \(number(size.id)), \(label(size.id))")
                        .gesture(DragGesture().onChanged { value in
                            guard model.previewSeconds == 0 else { return }
                            dragging = size.id; dragOffset = value.translation
                        }.onEnded { value in
                            defer { dragging = nil; dragOffset = .zero }
                            guard model.previewSeconds == 0 else { return }
                            let p = draft.origins[size.id] ?? .init(x: 0,y: 0)
                            draft = draft.moving(size.id,to: .init(x: p.x+value.translation.width/s,y: p.y+value.translation.height/s),sizes: sizes)
                        })
                }
            }
        }
    }
}
