import MapKit
import SwiftData
import SwiftUI
import iWalkCore

struct PlannerView: View {
    @Environment(PlannerModel.self) private var model
    @Environment(NetworkMonitor.self) private var network
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var context

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: AppConfig.mombasa.clCoordinate,
                           span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)))
    @State private var showingSave = false
    @State private var routeName = ""
    @State private var saveError: String?
    @State private var locationManager = CLLocationManager()

    var body: some View {
        @Bindable var model = model
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                if let planned = model.planned {
                    MapPolyline(coordinates: planned.coords.map(\.clCoordinate))
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, point in
                    Annotation("", coordinate: point.clCoordinate) {
                        WaypointHandle(index: index, isStart: index == 0)
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                    .onEnded { value in
                                        if let c = proxy.convert(value.location, from: .global) {
                                            model.move(at: index, to: Coordinate(c))
                                        }
                                    }
                            )
                            .contextMenu {
                                Button("Delete point", systemImage: "trash", role: .destructive) {
                                    model.remove(at: index)
                                }
                            }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onTapGesture(coordinateSpace: .global) { point in
                if let c = proxy.convert(point, from: .global) {
                    model.add(Coordinate(c))
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if !network.isOnline {
                Banner(text: "Planning needs internet. Saved routes still work.", systemImage: "wifi.slash")
            } else if let error = model.error {
                Banner(text: error, systemImage: "exclamationmark.triangle")
            } else if model.planned?.source == .apple {
                Banner(text: "Using Apple walking directions (no trails or elevation).", systemImage: "info.circle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            PlannerPanel(showingSave: $showingSave, routeName: $routeName)
        }
        .onAppear {
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        }
        .alert(model.editingRoute == nil ? "Save route" : "Update route", isPresented: $showingSave) {
            TextField("Name", text: $routeName)
            Button("Save") {
                do {
                    try model.save(name: routeName, context: context, sync: sync)
                } catch {
                    saveError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could not save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }
}

private struct WaypointHandle: View {
    let index: Int
    let isStart: Bool

    var body: some View {
        Text("\(index + 1)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(isStart ? Color.green : Color.blue))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
            .contentShape(Circle().inset(by: -8))
            .accessibilityLabel("Waypoint \(index + 1)")
    }
}

private struct PlannerPanel: View {
    @Environment(PlannerModel.self) private var model
    @Binding var showingSave: Bool
    @Binding var routeName: String

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 12) {
            Picker("Activity", selection: $model.activity) {
                ForEach(ActivityKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Loop", isOn: $model.isLoop).fixedSize()
                Spacer()
                if model.isPlanning { ProgressView().controlSize(.small) }
                Text(model.waypoints.isEmpty ? "Tap the map to add points" : "\(model.waypoints.count) points")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let planned = model.planned {
                HStack {
                    Stat(title: "Distance", value: Format.distance(km: planned.distanceKm))
                    Stat(title: "Time", value: Format.minutes(planned.durationMin))
                    Stat(title: "Climb", value: planned.elevGainM.map { "\(Int($0.rounded())) m" } ?? "—")
                }
                if let elevation = planned.elevation, let interval = planned.elevationIntervalM {
                    ElevationChart(elevation: elevation, intervalM: interval)
                        .frame(height: 90)
                }
            }

            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .disabled(model.waypoints.isEmpty)
                Button("Clear", systemImage: "xmark", role: .destructive) { model.clear() }
                    .disabled(model.waypoints.isEmpty && model.editingRoute == nil)
                Spacer()
                Button(model.editingRoute == nil ? "Save" : "Update", systemImage: "square.and.arrow.down") {
                    routeName = model.suggestedName
                    showingSave = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }
            .labelStyle(.titleAndIcon)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 4)
    }
}
