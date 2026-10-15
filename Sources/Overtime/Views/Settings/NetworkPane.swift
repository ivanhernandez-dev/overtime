import OvertimeAppSupport
import SwiftUI

struct NetworkPane: View {
  let model: SettingsModel

  var body: some View {
    Form {
      SaveErrorSection(model: model)
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Picker(HotspotChoice.pickerLabel, selection: selection) {
            ForEach(Array(model.hotspotEntries.enumerated()), id: \.offset) { _, entry in
              switch entry {
              case .divider:
                Divider()
              case .choice(let choice):
                Text(choice.label)
                  .truncationMode(.middle)
                  .tag(choice)
              }
            }
          }
          .pickerStyle(.menu)
          .disabled(!model.canEdit)
          .help(model.hotspotChoice.label)
          if let caption = model.hotspotCaption {
            SettingsSectionCaption(text: caption)
          }
        }
      } footer: {
        SettingsSectionCaption(text: HotspotPicker.sectionCaption)
      }
      if let row = model.locationRow {
        Section {
          LocationRowView(row: row, model: model)
        } footer: {
          SettingsSectionCaption(text: LocationRow.caption)
        }
      }
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
    .task {
      model.refreshLocationStatus()
      await model.readKnownNetworks()
    }
  }

  private var selection: Binding<HotspotChoice> {
    Binding(
      get: { model.hotspotChoice },
      set: { choice in
        Task { await model.selectHotspot(choice) }
      })
  }
}

struct LocationRowView: View {
  let row: LocationRow
  let model: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(symbol: row.symbol, tint: tint, title: row.title)
      switch row.action {
      case .allowLocation:
        Button(LocationRow.allowLabel) { model.allowLocationAccess() }
          .buttonStyle(.bordered)
          .controlSize(.regular)
      case .openLocationServices:
        Button(LocationRow.openLabel) { model.openLocationServices() }
          .buttonStyle(.link)
          .font(.subheadline)
      case nil:
        EmptyView()
      }
    }
  }

  private var tint: Color {
    switch row.tone {
    case .success: .green
    case .info: .secondary
    case .warning: .orange
    }
  }
}
