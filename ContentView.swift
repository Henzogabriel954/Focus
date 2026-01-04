import SwiftUI
import AVFoundation
import AppKit

// MARK: - Models

struct PomodoroCycle: Codable, Identifiable, Hashable {
    let id: String
    let date: Date
    let studyActual: Int
    let breakActual: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case date = "date_record"
        case studyActual = "study_actual"
        case breakActual = "break_actual"
        case updatedAt = "updated_at"
    }
    
    enum LegacyCodingKeys: String, CodingKey {
        case date
        case studyActual
        case breakActual
    }
    
    init(date: Date, studyActual: Int, breakActual: Int) {
        self.id = UUID().uuidString
        self.date = date
        self.studyActual = studyActual
        self.breakActual = breakActual
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        
        // Try new keys first (Server/New Local)
        let newDate = try container.decodeIfPresent(Date.self, forKey: .date)
        let newStudy = try container.decodeIfPresent(Int.self, forKey: .studyActual)
        let newBreak = try container.decodeIfPresent(Int.self, forKey: .breakActual)
        let updatedDate = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        
        // Try legacy keys (Old Local Data)
        let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        let oldDate = try legacyContainer?.decodeIfPresent(Date.self, forKey: .date)
        let oldStudy = try legacyContainer?.decodeIfPresent(Int.self, forKey: .studyActual)
        let oldBreak = try legacyContainer?.decodeIfPresent(Int.self, forKey: .breakActual)
        
        // Resolve final values (New > Old > Fallback)
        date = newDate ?? oldDate ?? updatedDate ?? Date()
        studyActual = newStudy ?? oldStudy ?? 0
        breakActual = newBreak ?? oldBreak ?? 0
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(studyActual, forKey: .studyActual)
        try container.encode(breakActual, forKey: .breakActual)
    }
    
    // Helpers for View grouping
    var dateKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
    
    var timeKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Services

class SyncService {
    static let shared = SyncService()
    
    private init() {}
    
    func sync(code: String, localCycles: [PomodoroCycle], completion: @escaping ([PomodoroCycle]?) -> Void) {
        let url = URL(string: "https://p2.hcraft.online/sync.php")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        struct SyncRequest: Encodable {
            let code: String
            let history: [PomodoroCycle]
        }
        
        let payload = SyncRequest(code: code, history: localCycles)
        
        let encoder = JSONEncoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX") // Ensure 24h format, no AM/PM
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        
        do {
            let jsonData = try encoder.encode(payload)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("Sending JSON: \(jsonString)")
            }
            request.httpBody = jsonData
            
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil else {
                    print("Sync error: \(error?.localizedDescription ?? "Unknown error")")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("Server Response: \(jsonString)")
                }
                
                let decoder = JSONDecoder()
                
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                let sqlFormatter = DateFormatter()
                sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                sqlFormatter.locale = Locale(identifier: "en_US_POSIX")
                sqlFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    
                    if let date = isoFormatter.date(from: dateString) {
                        return date
                    }
                    
                    // Try basic ISO if fractional seconds failed
                    let basicIsoFormatter = ISO8601DateFormatter()
                    if let date = basicIsoFormatter.date(from: dateString) {
                        return date
                    }
                    
                    if let date = sqlFormatter.date(from: dateString) {
                        return date
                    }
                    
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
                }
                
                // Helper struct for dictionary response
                struct SyncResponse: Decodable {
                    let history: [PomodoroCycle]
                }
                
                do {
                    // Try to decode as a Dictionary first (since the error indicates it's a dictionary)
                    let wrapper = try decoder.decode(SyncResponse.self, from: data)
                    DispatchQueue.main.async {
                        completion(wrapper.history)
                    }
                } catch let dictionaryError {
                    // If dictionary decoding fails, try array (legacy/fallback)
                    do {
                        let remoteCycles = try decoder.decode([PomodoroCycle].self, from: data)
                        DispatchQueue.main.async {
                            completion(remoteCycles)
                        }
                    } catch {
                        // Both failed. Analyze the dictionary error as it's the most relevant given the "typeMismatch" original error.
                        print("Sync decoding error (Dictionary): \(dictionaryError)")
                        print("Sync decoding error (Array): \(error)")
                        
                        if let jsonString = String(data: data, encoding: .utf8) {
                            print("Received JSON: \(jsonString)")
                        }
                        
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            }.resume()
            
        } catch {
            print("Encoding error: \(error)")
            completion(nil)
        }
    }
}

struct CycleData {
    var studyTime: Int
    var breakTime: Int
    var studyActual: Int = 0
    var breakActual: Int = 0
}

enum AppTheme: String, CaseIterable {
    case auto = "Auto"
    case light = "Light"
    case dark = "Dark"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - ViewModel

class PomodoroTimerState: ObservableObject {
    @Published var studyTimeMinutes: Int = 25 {
        didSet {
            UserDefaults.standard.set(studyTimeMinutes, forKey: "pomodoro_study_time")
            if !isRunning && isStudyMode && timeLeft > 0 { resetTimer() }
        }
    }
    @Published var breakTimeMinutes: Int = 5 {
        didSet {
            UserDefaults.standard.set(breakTimeMinutes, forKey: "pomodoro_break_time")
            if !isRunning && !isStudyMode && timeLeft > 0 { resetTimer() }
        }
    }
    
    @Published var isStudyMode: Bool = true
    @Published var isRunning: Bool = false
    @Published var isPaused: Bool = false
    @Published var timeLeft: Double = 0
    @Published var totalTimeInPhase: Double = 0
    
    @Published var cycles: [PomodoroCycle] = []
    @Published var currentTheme: AppTheme = .auto
    @Published var backgroundOpacity: Double = 0.0
    
    @Published var showPhaseEndAlert: Bool = false
    @Published var alertMessage: String = ""
    
    // Logic for overtime
    var isOvertime: Bool {
        return timeLeft <= 0
    }
    
    var progress: Double {
        if timeLeft <= 0 { return 1.0 }
        guard totalTimeInPhase > 0 else { return 0 }
        return 1 - (timeLeft / totalTimeInPhase)
    }
    
    var currentCycleData: CycleData?
    private var timerInterval: Timer?
    
    init() {
        loadSettings()
        loadCycles()
        loadTheme()
        loadOpacity()
        resetTimer()
    }
    
    var timerDisplay: String {
        let absTime = abs(timeLeft)
        let seconds = Int(ceil(absTime))
        let m = seconds / 60
        let s = seconds % 60
        let prefix = timeLeft <= 0 ? "+" : ""
        return String(format: "%@%02d:%02d", prefix, m, s)
    }
    
    var statusLabel: String {
        if isOvertime { return "Overtime" }
        return isStudyMode ? "Focus" : "Break"
    }
    
    var statusColor: Color {
        if isOvertime { return .red }
        return isStudyMode ? .blue : .green
    }
    
    func startSession() {
        if !isRunning && !isPaused && timeLeft > 0 {
            setupNewPhase()
        }
        isRunning = true
        isPaused = false
        startTimer()
    }
    
    func pauseSession() {
        isPaused = true
        isRunning = false
        stopTimer()
    }
    
    func resetSession() {
        stopTimer()
        isRunning = false
        isPaused = false
        resetTimer()
    }
    
    func skipPhase() {
        confirmPhaseSwitch()
    }
    
    func clearHistory() {
        cycles = []
        saveCycles()
    }
    
    // MARK: - Grouping Logic for History
    
    struct DayGroup: Identifiable {
        var id: String { date }
        let date: String
        let cycles: [PomodoroCycle]
        
        var totalStudy: Int { cycles.reduce(0) { $0 + $1.studyActual } }
        var totalBreak: Int { cycles.reduce(0) { $0 + $1.breakActual } }
    }
    
    var groupedCycles: [DayGroup] {
        let grouped = Dictionary(grouping: cycles) { $0.dateKey }
        return grouped.map { DayGroup(date: $0.key, cycles: $0.value.sorted(by: { $0.date > $1.date })) }
            .sorted { group1, group2 in
                guard let first1 = group1.cycles.first, let first2 = group2.cycles.first else { return false }
                return first1.date > first2.date
            }
    }
    
    // MARK: - Internal Logic
    
    private func setupNewPhase() {
        let minutes = isStudyMode ? studyTimeMinutes : breakTimeMinutes
        totalTimeInPhase = Double(minutes * 60)
        timeLeft = totalTimeInPhase
        
        if currentCycleData == nil {
             currentCycleData = CycleData(
                studyTime: studyTimeMinutes * 60,
                breakTime: breakTimeMinutes * 60
            )
        }
    }
    
    private func resetTimer() {
        let minutes = isStudyMode ? studyTimeMinutes : breakTimeMinutes
        totalTimeInPhase = Double(minutes * 60)
        timeLeft = totalTimeInPhase
    }
    
    private func startTimer() {
        stopTimer()
        timerInterval = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick(0.1)
        }
    }
    
    private func stopTimer() {
        timerInterval?.invalidate()
        timerInterval = nil
    }
    
    private func tick(_ delta: Double) {
        let previousTime = timeLeft
        timeLeft -= delta
        
        if previousTime > 0 && timeLeft <= 0 {
             triggerAlarm()
        }
        
        if let _ = currentCycleData {
            if isStudyMode {
                currentCycleData?.studyActual += Int(delta * 10)
            } else {
                currentCycleData?.breakActual += Int(delta * 10)
            }
        }
    }
    
    private func triggerAlarm() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                NSSound.beep()
            }
        }
        alertMessage = isStudyMode ? "Focus session complete!" : "Break over!"
        showPhaseEndAlert = true
    }
    
    func continueOvertime() {
        showPhaseEndAlert = false
    }
    
    func confirmPhaseSwitch() {
        showPhaseEndAlert = false
        stopTimer()
        
        // Ensure data exists even if we skipped without playing
        if currentCycleData == nil {
             currentCycleData = CycleData(
                studyTime: studyTimeMinutes * 60,
                breakTime: breakTimeMinutes * 60
            )
        }
        
        if !isStudyMode {
            saveCycle()
            currentCycleData = nil
        }
        
        isStudyMode.toggle()
        resetTimer()
        isRunning = true
        isPaused = false
        startTimer()
    }
    
    // MARK: - Persistence & Audio
    
    private func loadSettings() {
        let savedStudy = UserDefaults.standard.integer(forKey: "pomodoro_study_time")
        if savedStudy > 0 { studyTimeMinutes = savedStudy }
        
        let savedBreak = UserDefaults.standard.integer(forKey: "pomodoro_break_time")
        if savedBreak > 0 { breakTimeMinutes = savedBreak }
    }
    
    private func saveCycle() {
        guard let data = currentCycleData else { return }
        
        let newCycle = PomodoroCycle(
            date: Date(),
            studyActual: data.studyActual / 10,
            breakActual: data.breakActual / 10
        )
        
        print("Saving new cycle locally: \(newCycle)")
        cycles.insert(newCycle, at: 0)
        saveCycles()
    }
    
    func loadCycles() {
        if let data = UserDefaults.standard.data(forKey: "pomodoro_history") {
            let decoder = JSONDecoder()
            
            // Try standard/new format first
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            decoder.dateDecodingStrategy = .formatted(dateFormatter)
            
            if let saved = try? decoder.decode([PomodoroCycle].self, from: data) {
                self.cycles = saved
                return
            }
            
            // Fallback: Try default strategy (for old cache compatibility)
            let legacyDecoder = JSONDecoder()
            if let saved = try? legacyDecoder.decode([PomodoroCycle].self, from: data) {
                self.cycles = saved
            }
        }
    }
    
    func saveCycles() {
        let encoder = JSONEncoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        
        if let data = try? encoder.encode(cycles) {
            UserDefaults.standard.set(data, forKey: "pomodoro_history")
        }
    }
    
    private func loadTheme() {
        if let stored = UserDefaults.standard.string(forKey: "pomodoro_theme"),
           let theme = AppTheme(rawValue: stored) {
            currentTheme = theme
        }
    }
    
    private func saveTheme() {
        UserDefaults.standard.set(currentTheme.rawValue, forKey: "pomodoro_theme")
    }
    
    private func loadOpacity() {
        backgroundOpacity = UserDefaults.standard.double(forKey: "pomodoro_opacity")
    }
    
    func saveOpacity() {
        UserDefaults.standard.set(backgroundOpacity, forKey: "pomodoro_opacity")
    }
}

// MARK: - Reusable Views

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct CircularProgressView: View {
    var progress: Double
    var color: Color
    var size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: size * 0.04)
                .opacity(0.1)
                .foregroundColor(.primary)
            
            Circle()
                .trim(from: 0.0, to: CGFloat(min(self.progress, 1.0)))
                .stroke(style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round, lineJoin: .round))
                .foregroundColor(color)
                .rotationEffect(Angle(degrees: 270.0))
                .animation(.linear(duration: 0.2), value: progress)
                .animation(.linear(duration: 0.2), value: color)
        }
        .frame(width: size, height: size)
    }
}

struct MinimalButton: View {
    let icon: String
    let action: () -> Void
    var size: CGFloat = 20
    var scale: CGFloat = 1.0
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(isHovering ? .primary : .secondary)
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isHovering)
                .contentShape(Rectangle()) 
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .onHover { hover in
            isHovering = hover
        }
    }
}

struct PlayButton: View {
    let isRunning: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(isHovering ? 0.1 : 0.05))
                    .frame(width: 64, height: 64)
                
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.primary)
                    .offset(x: isRunning ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hover
            }
        }
    }
}

struct SettingsPopover: View {
    @ObservedObject var state: PomodoroTimerState
    @AppStorage("user_sync_code") var syncCode: String = ""
    @State private var isSyncing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Focus Duration")
                    Spacer()
                    TextField("25", value: $state.studyTimeMinutes, formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 50)
                    Text("min")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Break Duration")
                    Spacer()
                    TextField("5", value: $state.breakTimeMinutes, formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 50)
                    Text("min")
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Sincronização")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    TextField("Código de 6 dígitos", text: $syncCode)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button(action: {
                        isSyncing = true
                        SyncService.shared.sync(code: syncCode, localCycles: state.cycles) { remoteCycles in
                            isSyncing = false
                            if let remote = remoteCycles {
                                print("Merge - Local count: \(state.cycles.count)")
                                print("Merge - Remote count: \(remote.count)")
                                
                                // Merge logic: Combine local and remote, deduplicating by ID
                                var mergedMap = Dictionary(uniqueKeysWithValues: state.cycles.map { ($0.id, $0) })
                                for cycle in remote {
                                    mergedMap[cycle.id] = cycle
                                }
                                
                                let sortedCycles = mergedMap.values.sorted { $0.date > $1.date }
                                print("Merge - Final count: \(sortedCycles.count)")
                                
                                state.cycles = sortedCycles
                                state.saveCycles()
                            }
                        }
                    }) {
                        if isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Sincronizar")
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Text("Theme")
                Spacer()
                Picker("Theme", selection: $state.currentTheme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 150)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Style")
                    Spacer()
                    Text(state.backgroundOpacity == 0 ? "Blur" : (state.backgroundOpacity == 1 ? "Opaque" : "Mixed"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { state.backgroundOpacity },
                    set: { 
                        state.backgroundOpacity = $0
                        state.saveOpacity()
                    }
                ), in: 0...1)
                .accentColor(.gray)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - History Views

struct HistoryDetailPopover: View {
    let cycle: PomodoroCycle
    
    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Session Details")
                .font(.headline)
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Focus Time")
                        .foregroundColor(.secondary)
                    Text(formatDuration(cycle.studyActual))
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Break Time")
                        .foregroundColor(.secondary)
                    Text(formatDuration(cycle.breakActual))
                        .font(.title3)
                        .foregroundColor(.green)
                }
            }
            Text("Completed at \(cycle.timeKey)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 200)
    }
}

struct HistoryDayGroupView: View {
    let group: PomodoroTimerState.DayGroup
    @State private var isExpanded: Bool = false
    
    private func formatTotal(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(s)s"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.date)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if isExpanded {
                            Text("Total: \(formatTotal(group.totalStudy)) Focus • \(formatTotal(group.totalBreak)) Break")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // List
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(group.cycles) { cycle in
                        HistoryItemRow(cycle: cycle)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 8)
            }
        }
    }
}

struct HistoryItemRow: View {
    let cycle: PomodoroCycle
    @State private var showDetails = false
    
    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%dm %02ds", m, s)
    }
    
    var body: some View {
        Button(action: { showDetails.toggle() }) {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.blue)
                Text(cycle.timeKey)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
                Text("Focus: \(formatDuration(cycle.studyActual))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails) {
            HistoryDetailPopover(cycle: cycle)
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var state = PomodoroTimerState()
    @State private var showSettings = false
    @State private var showHistory = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                ZStack {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    Color(NSColor.windowBackgroundColor)
                        .opacity(state.backgroundOpacity)
                }
                .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        MinimalButton(icon: "clock.arrow.circlepath", action: { showHistory.toggle() })
                            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("History")
                                            .font(.headline)
                                        Spacer()
                                        Button("Clear") { state.clearHistory() }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.red)
                                            .font(.caption)
                                    }
                                    .padding()
                                    
                                    ScrollView {
                                        VStack(spacing: 12) {
                                            if state.cycles.isEmpty {
                                                Text("No completed cycles yet.")
                                                    .foregroundColor(.secondary)
                                                    .font(.caption)
                                                    .padding()
                                            } else {
                                                ForEach(state.groupedCycles) { group in
                                                    HistoryDayGroupView(group: group)
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                        .padding(.bottom)
                                    }
                                    .frame(width: 300, height: 400)
                                }
                            }
                        
                        Spacer()
                        
                        // Status Indicator (Small)
                        if state.isRunning {
                            Circle()
                                .fill(state.statusColor)
                                .frame(width: 6, height: 6)
                        }
                        
                        Spacer()
                        
                        MinimalButton(icon: "slider.horizontal.3", action: { showSettings.toggle() })
                            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                                SettingsPopover(state: state)
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    
                    Spacer(minLength: 0)
                    
                    // Adaptive Timer Display
                    let minDimension = min(geometry.size.width, geometry.size.height)
                    let timerSize = max(200, minDimension * 0.5)
                    
                    ZStack {
                        CircularProgressView(
                            progress: state.progress,
                            color: state.statusColor,
                            size: timerSize
                        )
                        
                        VStack(spacing: 4) {
                            Text(state.statusLabel)
                                .font(.system(size: timerSize * 0.1, weight: .medium, design: .rounded))
                                .foregroundColor(state.isOvertime ? .red : .secondary)
                                .animation(.default, value: state.statusLabel)
                            
                            Text(state.timerDisplay)
                                .font(.system(size: timerSize * 0.25, weight: .light, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(state.isOvertime ? .red : .primary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Controls
                    HStack(spacing: 40) {
                        MinimalButton(icon: "arrow.counterclockwise", action: { state.resetSession() }, size: 18)
                            .help("Reset Timer")
                        
                        PlayButton(isRunning: state.isRunning) {
                            if state.isRunning {
                                state.pauseSession()
                            } else {
                                state.startSession()
                            }
                        }
                        
                        MinimalButton(icon: "forward.end", action: { state.skipPhase() }, size: 18)
                            .help("Skip Phase")
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 450)
        .preferredColorScheme(state.currentTheme.colorScheme)
        .alert(isPresented: $state.showPhaseEndAlert) {
            Alert(
                title: Text(state.isStudyMode ? "Focus Complete" : "Break Complete"),
                message: Text("What would you like to do?"),
                primaryButton: .default(Text("Next Phase"), action: {
                    state.confirmPhaseSwitch()
                }),
                secondaryButton: .cancel(Text("Continue \(state.isStudyMode ? "Focusing" : "Resting")"), action: {
                    state.continueOvertime()
                })
            )
        }
    }
}

#Preview {
    ContentView()
}
