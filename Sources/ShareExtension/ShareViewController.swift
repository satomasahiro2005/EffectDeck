//  ShareViewController.swift
//  共有シートの EffectDeck。受けたものを App Group の Inbox へ置くだけ。
//
//  **判定はしない。**音か JSFX かは本体の ETInbox.receive が中身で決める
//  （拡張は DSP も IRLibrary も持たない）。本体は前へ出たときに Inbox を拾う
//  （ETShareInbox.drain）。
//
//  ここは画面だけ。受けたものを選んで置くところは ShareModel.swift（単体テストに入る）。

import SwiftUI
import UIKit

final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] added in
            guard let context = self?.extensionContext else { return }
            if added {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        model.load(providers)
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Text(model.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("EffectDeck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy {
                        ProgressView()
                    } else {
                        Button("Add") { model.add() }
                            .disabled(model.item == nil)
                    }
                }
            }
        }
    }
}
