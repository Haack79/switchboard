import SwiftUI
import SwitchboardCore

extension View {
  /// The main window's toolbar. macOS 26 draws each group in its own capsule and puts the system's gap between groups.
  /// Earlier versions draw no capsules and get no spacers. Apply it to the split view's detail column. On the split
  /// view itself, SwiftUI puts every spacer in the sidebar's part of the toolbar.
  @ViewBuilder func mainToolbar() -> some View {
    if #available(macOS 26, *) {
      toolbar {
        NavHistoryControls()
        // A spacer with the navigation placement lands after the picker, so the picker takes the default placement.
        ToolbarSpacer(.fixed)
        ToolbarItem { ViewPicker() }
        ToolbarSpacer(.flexible)
        ToolbarItem { SessionFilterMenu() }
        ToolbarSpacer(.fixed)
        AccountItems()
        ToolbarSpacer(.fixed)
        ToolbarItem { ImportButton() }
        ToolbarSpacer(.fixed)
        ToolbarItem { NewSessionButton() }
      }
    } else {
      toolbar {
        NavHistoryControls()
        ToolbarItem(placement: .navigation) { ViewPicker() }
        ToolbarItem { SessionFilterMenu() }
        AccountItems()
        ToolbarItem { ImportButton() }
        ToolbarItem { NewSessionButton() }
      }
    }
  }
}

/// The Manager and account buttons, which share one capsule.
private struct AccountItems: ToolbarContent {
  var body: some ToolbarContent {
    ToolbarItemGroup {
      ManagerButton()
      AccountMenu()
    }
  }
}

/// Inbox, Board, and Issues. No segment is selected while a session shows.
private struct ViewPicker: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Picker(
      "View",
      selection: Binding(
        get: { model.selected == nil ? model.mainView : nil },
        set: { if let view = $0 { model.show(view) } })
    ) {
      Text(ContentView.viewLabel("Inbox", model.triage.count)).tag(MainView?.some(.inbox))
      Text("Board").tag(MainView?.some(.board))
      Text(ContentView.viewLabel("Issues", model.issueCount)).tag(MainView?.some(.issues))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .help("Show the Inbox (⌘1), the Board (⌘2), or Issues (⌘3)")
  }
}

private struct ImportButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button {
      model.showingImport = true
    } label: {
      Label("Import Sessions", systemImage: "square.and.arrow.down")
    }
    .help("Import Claude sessions that run outside Switchboard (⇧⌘I)")
  }
}

private struct NewSessionButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button {
      model.openNewSession()
    } label: {
      Label("New Session", systemImage: "plus")
    }
    .help("Start a session (⌘N)")
  }
}
