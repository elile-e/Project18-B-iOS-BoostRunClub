//
//  RunningDataService.swift
//  BoostRunClub
//
//  Created by 조기현 on 2020/12/01.
//

import Combine
import CoreLocation
import CoreMotion
import Foundation

protocol RunningDataServiceable {
    var runningTime: CurrentValueSubject<TimeInterval, Never> { get }
    var distance: CurrentValueSubject<Double, Never> { get }
    var pace: CurrentValueSubject<Int, Never> { get }
    var calorie: CurrentValueSubject<Int, Never> { get }
    var avgPace: CurrentValueSubject<Int, Never> { get }
    var cadence: CurrentValueSubject<Int, Never> { get }
    var newSplitSubject: PassthroughSubject<RunningSplit, Never> { get }
    var runningEvent: PassthroughSubject<RunningEvent, Never> { get }

    var isRunning: Bool { get }
    var currentLocation: PassthroughSubject<CLLocationCoordinate2D, Never> { get }
    var locations: [CLLocation] { get }
    var runningSplits: [RunningSplit] { get }
    var currentRunningSlice: RunningSlice { get }
    var routes: [RunningSlice] { get }
    var currentMotionType: CurrentValueSubject<MotionType, Never> { get }
    var stopRunningResponse: PassthroughSubject<(activity: Activity, detail: ActivityDetail)?, Never> { get }
    func start()
    func stop()
    func pause()
    func resume()
}

class RunningDataService: RunningDataServiceable {
    var locationProvider: LocationProvidable
    var mapSnapShotService: MapSnapShotServiceable
    var activityWriter: ActivityWritable

    var cancellables = Set<AnyCancellable>()

    var startTime = Date()
    var endTime = Date()
    var lastUpdatedTime: TimeInterval = 0

    var currentLocation = PassthroughSubject<CLLocationCoordinate2D, Never>()
    var stopRunningResponse = PassthroughSubject<(activity: Activity, detail: ActivityDetail)?, Never>()

    var runningTime = CurrentValueSubject<TimeInterval, Never>(0)
    var calorie = CurrentValueSubject<Int, Never>(0)
    var pace = CurrentValueSubject<Int, Never>(0)
    var avgPace = CurrentValueSubject<Int, Never>(0)
    var cadence = CurrentValueSubject<Int, Never>(0)
    var distance = CurrentValueSubject<Double, Never>(0)
    var newSplitSubject = PassthroughSubject<RunningSplit, Never>()
    var runningEvent = PassthroughSubject<RunningEvent, Never>()
    var locations = [CLLocation]()

    var runningSplits = [RunningSplit]()
    var currentRunningSplit = RunningSplit()
    var currentRunningSlice = RunningSlice()
    var routes: [RunningSlice] {
        runningSplits.flatMap { $0.runningSlices } + currentRunningSplit.runningSlices + [currentRunningSlice]
    }

    var currentMotionType = CurrentValueSubject<MotionType, Never>(.standing)

    private(set) var isRunning: Bool = false
    let eventTimer: EventTimerProtocol

    init(
        eventTimer: EventTimerProtocol = EventTimer(),
        locationProvider: LocationProvidable,
        motionProvider: MotionProvider,
        activityWriter: ActivityWritable,
        mapSnapShotService: MapSnapShotServiceable
    ) {
        motionProvider.startUpdating()

        self.eventTimer = eventTimer
        self.locationProvider = locationProvider
        self.activityWriter = activityWriter
        self.mapSnapShotService = mapSnapShotService

        locationProvider.locationSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self = self else { return }
                self.updateLocation(location: location)
                self.updateTime(currentTime: location.timestamp.timeIntervalSinceReferenceDate)
            }
            .store(in: &cancellables)

        eventTimer.timeSubject
            .sink { [weak self] time in
                self?.updateTime(currentTime: time)
            }
            .store(in: &cancellables)

        motionProvider.currentMotionType
            .sink { [weak self] currentMotionType in
                self?.currentMotionType.send(currentMotionType)
            }
            .store(in: &cancellables)

        motionProvider.cadence
            .sink { [weak self] cadence in
                self?.cadence.value = cadence
            }.store(in: &cancellables)
    }

    func initializeRunningData() {
        startTime = Date()
        lastUpdatedTime = Date.timeIntervalSinceReferenceDate
        runningTime.value = 0
        pace.value = 0
        avgPace.value = 0
        distance.value = 0
        locations.removeAll()
        currentRunningSlice = RunningSlice()
        currentRunningSplit = RunningSplit()
        runningSplits.removeAll()
    }

    func start() {
        if !isRunning {
            isRunning = true
            eventTimer.start()
            locationProvider.startBackgroundTask()
            initializeRunningData()
        }
        runningEvent.send(RunningEvent.start)
    }

    func stop() {
        addSplit()
        locationProvider.stopBackgroundTask()
        eventTimer.stop()
        endTime = Date()
        if !locations.isEmpty {
            runningEvent.send(RunningEvent.stop)
            mapSnapShotService.takeSnapShot(from: locations, dimension: 100)
                .receive(on: RunLoop.main)
                .replaceError(with: nil)
                .first()
                .sink { [weak self] data in
                    self?.saveRunning(with: data)
                }
                .store(in: &cancellables)
        } else {
            stopRunningResponse.send(nil)
        }
        isRunning = false
    }

    func pause() {
        addSlice()
        isRunning = false
        runningEvent.send(RunningEvent.pause)
    }

    func resume() {
        addSlice()
        isRunning = true
        runningEvent.send(RunningEvent.resume)
    }

    func addSlice() {
        if locations.isEmpty { return }
        currentRunningSlice.isRunning = isRunning
        currentRunningSlice.setupSlice(with: locations)
        currentRunningSplit.runningSlices.append(currentRunningSlice)

        currentRunningSlice = RunningSlice()
        currentRunningSlice.startIndex = locations.count - 1
    }

    func addSplit() {
        addSlice()
        // TODO: bpm, elevation 값 설정해주기
        currentRunningSplit.setupSplit(bpm: 0, avgPace: avgPace.value, elevation: 0)
        runningSplits.append(currentRunningSplit)
        newSplitSubject.send(currentRunningSplit)

        currentRunningSplit = RunningSplit()
    }

    func updateTime(currentTime: TimeInterval) {
        if isRunning {
            runningTime.value += currentTime - lastUpdatedTime
        }
        lastUpdatedTime = currentTime
    }

    func updateLocation(location: CLLocation) {
        currentLocation.send(location.coordinate)

        if isRunning, let prevLocation = locations.last {
            let addedDistance = location.distance(from: prevLocation)
            let newDistance = addedDistance + distance.value

            //	킬로미터 * Motion상수 * weight
            calorie.value += Int(addedDistance / 1000 * currentMotionType.value.METFactor * 70)

            if Int(newDistance / 1000) - Int(distance.value / 1000) > 0 {
                addSplit()
            }
            distance.value = newDistance
        }

        let paceDouble = 1000 / location.speed
        if !(paceDouble.isNaN || paceDouble.isInfinite) {
            pace.value = Int(paceDouble)
        }

        locations.append(location)
        avgPace.value = (avgPace.value * (locations.count - 1) + pace.value) / locations.count
    }

    private func saveRunning(with data: Data?) {
        let uuid = UUID()

        let activity = Activity(
            avgPace: avgPace.value,
            distance: distance.value,
            duration: runningTime.value,
            elevation: 0, // TODO: elevation 값 저장
            thumbnail: data,
            createdAt: startTime,
            finishedAt: Date(),
            uuid: uuid
        )

        let activityDetail = ActivityDetail(
            activityUUID: uuid,
            avgBPM: 0,
            cadence: cadence.value,
            calorie: Int(calorie.value),
            elevation: 0,
            locations: locations.map { Location(clLocation: $0) },
            splits: runningSplits
        )
        stopRunningResponse.send((activity, activityDetail))
        activityWriter.addActivity(activity: activity, activityDetail: activityDetail)
    }
}
