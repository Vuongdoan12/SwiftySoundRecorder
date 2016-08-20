//
//  SwiftySoundRecorder.swift
//  SwiftySoundRecorder
//
//  Created by Guoliang Wang on 8/12/16.
//
//

import UIKit

import AVFoundation
import SCSiriWaveformView
import FDWaveformViewForked

internal enum SwiftySoundMode {
    case Recording
    case Playing
    case Idling
    case Cropping
}

public protocol SwiftySoundRecorderDelegate: class {
    func doneRecordingDidPress(soundRecorder: SwiftySoundRecorder, audioFilePath: String)
    func cancelRecordingDidPress(soundRecorder: SwiftySoundRecorder)
}

public class SwiftySoundRecorder: UIViewController {
    
    public weak var delegate: SwiftySoundRecorderDelegate?
    public var navBarButtonLabelsDict = Configuration.navBarButtonLabelsDict
    public var maxDuration: CGFloat = 0
    public var allowCropping: Bool = true
    
    private var statusBarHidden: Bool = false
    private var audioDuration: NSTimeInterval = 0
    private var audioRecorder: AVAudioRecorder? = nil
    private var audioPlayer: AVAudioPlayer? = nil
    private let audioFileType = "m4a" // AVFileTypeAppleM4A --> "com.apple.m4a-audio"
    private var curAudioPathStr: String? = nil
    private var isCroppingEnabled: Bool = false
    private var audioTimer = NSTimer() // used for both recording and playing
    
    private var waveNormalTintColor = Configuration.recorderWaveNormalTintColor
    private var waveHighlightedTintColor = Configuration.recorderWaveHighlightedTintColor
    private let frostedView = UIVisualEffectView(effect: UIBlurEffect(style: .Dark))
    private let waveUpdateInterval: NSTimeInterval = 0.01
    private let navbarHeight: CGFloat = Configuration.navBarHeight
    private let fileManager = NSFileManager.defaultManager()
    private var leftPanGesture: UIPanGestureRecognizer!
    private var rightPanGesture: UIPanGestureRecognizer!
    private var _operationMode: SwiftySoundMode = .Idling
    
    private var operationMode: SwiftySoundMode = .Idling {
        willSet(newValue) {
            if _operationMode != newValue {
                print("updating UI now")
                self.updateUIForOperation(newValue)
            }
            _operationMode = newValue
        }
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        fileManager.delegate = self
        curAudioPathStr = nil
        operationMode = .Idling
        setupUI()
    }
    
    override public func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        statusBarHidden = UIApplication.sharedApplication().statusBarHidden
        UIApplication.sharedApplication().setStatusBarHidden(statusBarHidden, withAnimation: .Fade)
    }
    
    public override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    public override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        
        audioTimer.invalidate()
        audioPlayer = nil
        audioRecorder = nil
        // TODO: clean up unwanted recordings
    }
    
    @objc private func togglePlayRecording(sender: AnyObject?) {
        
        guard let pathStr = curAudioPathStr else {return}
        let audioFileUrl = NSURL(string: pathStr)!
        
        if audioPlayer == nil {
            do {
                try audioPlayer = AVAudioPlayer(contentsOfURL: audioFileUrl, fileTypeHint: audioFileType)
                audioPlayer!.delegate = self
                audioPlayer!.rate = 1.0
                audioPlayer!.prepareToPlay()
            } catch let error {
                print("error in creating audio player: \(error)")
            }
        }
        audioDuration = audioPlayer!.duration
        
        // MARK: internal functions for playing and pausing player
        func __playNow() {
            audioPlayer!.play()
            playButton.setBackgroundImage(self.pauseIcon, forState: .Normal)
        }
        
        func __pauseNow() {
            audioPlayer!.pause()
            audioTimer.invalidate()
            playButton.setBackgroundImage(self.playIcon, forState: .Normal)
        }
        
        if operationMode == .Cropping && audioPlayer!.playing {
            __pauseNow()
        } else if operationMode == .Cropping && !audioPlayer!.playing {
            if audioPlayer!.currentTime <= NSTimeInterval(leftCropper.cropTime) {
                // always play from the crop time in Cropping mode
                audioPlayer!.currentTime = NSTimeInterval(leftCropper.cropTime)
            }
            __playNow()
        } else {
            operationMode = .Playing
            audioPlayer!.meteringEnabled = true
            
            if audioPlayer!.playing {
                __pauseNow()
            } else {
                audioTimer = NSTimer.scheduledTimerWithTimeInterval(waveUpdateInterval, target: self, selector: #selector(self.audioTimerCallback), userInfo: nil, repeats: true)
                __playNow()
            }
        }
    }
    
    @objc private func stopRecording(sender: AnyObject?) {
        self.operationMode = .Idling
        guard let recorder = audioRecorder else { return }
        if recorder.recording {
            recorder.stop()
        }
    }
    
    @objc private func toggleRecording(sender: AnyObject?) {
        
        self.operationMode = .Recording
        
        if audioRecorder == nil {
            // initialize audio recorder, remove existing audio file, if any
            do {
                if fileManager.fileExistsAtPath(originalRecordedAudioURL.path!) {
                    try fileManager.removeItemAtURL(originalRecordedAudioURL)
                }
                try audioRecorder = AVAudioRecorder(URL: originalRecordedAudioURL, settings: recorderSettings)
                audioDuration = (maxDuration > 0) ? NSTimeInterval(maxDuration) : 0 // if maxDuration > 0 -> count down, otherwise count up
            } catch let error {
                print("error in recording: \(error)")
            }
        }
        
        if audioRecorder!.recording {
            audioRecorder!.pause()
            audioTimer.invalidate()
            micButton.setBackgroundImage(micIcon, forState: .Normal)
        } else {
            audioRecorder!.prepareToRecord()
            audioRecorder!.meteringEnabled = true
            audioRecorder!.delegate = self
            audioTimer = NSTimer.scheduledTimerWithTimeInterval(waveUpdateInterval, target: self, selector: #selector(self.audioTimerCallback), userInfo: nil, repeats: true)
            audioRecorder!.record()
            micButton.setBackgroundImage(pauseIcon, forState: .Normal)
        }
    }
    
    @objc private func beginAudioCropMode(sender: AnyObject?) {
        
        guard allowCropping else { return }
        
        guard let filePathStr = curAudioPathStr else { return }
        self.operationMode = .Cropping // TODO: stop audioRecorder, player, buttons etc.
        destroyPlayer()

        let fileURL = NSURL(fileURLWithPath: filePathStr)
        self.waveFormView.audioURL = fileURL
        
        if isCroppingEnabled && sender as! UIButton == scissorButton {
            // TODO: warning when the trimmed audio is less than 2 seconds
            trimAudio(fileURL, startTime: leftCropper.cropTime, endTime: rightCropper.cropTime)
        }
    }
    
    private func _loadCroppers() {

        self.leftCropper.cropTime = 0
        self.rightCropper.cropTime = CGFloat(self.audioDuration)
        if !audioWaveContainerView.subviews.contains(leftCropper) {
            runOnMainQueue(callback: {
                self.audioWaveContainerView.addSubview(self.leftCropper)
                self.audioWaveContainerView.addSubview(self.rightCropper)
            })
        }
        // position the croppers
        runOnMainQueue { 
            self.leftCropper.frame = CGRectMake(0, 0, 30, self.audioWaveContainerView.bounds.height)
            self.rightCropper.frame = CGRect(x: self.audioWaveContainerView.bounds.width - 30, y: 0, width: 30, height: self.audioWaveContainerView.bounds.height)
            
            self.audioWaveContainerView.bringSubviewToFront(self.leftCropper)
            self.audioWaveContainerView.bringSubviewToFront(self.rightCropper)
            UIView.animateWithDuration(3.0, animations: {
                self.leftCropper.alpha = 1.0
                self.rightCropper.alpha = 1.0
            })
        }
    }
    
    @objc private func audioTimerCallback() {
        var remainingTime: NSTimeInterval = 0
        if self.operationMode == .Playing && audioPlayer != nil {
            audioPlayer!.updateMeters()
            remainingTime = audioPlayer!.currentTime // count up for playing
            audioSiriWaveView.updateWithLevel(CGFloat(pow(10, audioPlayer!.averagePowerForChannel(0)/20)))
            
        } else if self.operationMode == .Recording && audioRecorder != nil {
            audioRecorder!.updateMeters()
            if maxDuration > 0 {

                remainingTime = NSTimeInterval(maxDuration) - audioRecorder!.currentTime  // count down for recording if maxDuration is set

                if audioRecorder!.currentTime >= NSTimeInterval(maxDuration) {
                    self.stopRecording(nil)
                } else if (remainingTime <= 6) {
                    // Give warning when the remaining time is 6 sec or less
                    if Int(remainingTime) % 2 == 1 {
                        clockIcon.tintColor = UIColor.redColor()
                        timeLabel.textColor = UIColor.redColor()
                    } else {
                        clockIcon.tintColor = UIColor(white: 1, alpha: 0.9)
                        timeLabel.textColor = UIColor(white: 1, alpha: 0.9)
                    }
                }
            } else {
                remainingTime = audioRecorder!.currentTime // count up
            }
            
            audioSiriWaveView.updateWithLevel(CGFloat(pow(10, audioRecorder!.averagePowerForChannel(0)/20)))
        }
        _updateTimeLabel(remainingTime + 0.15) // TODO: use UISlider for playing, move this line to recorder block
    }
    
    @objc private func destroyPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioTimer.invalidate()
        playButton.setBackgroundImage(playIcon, forState: .Normal)
    }
    
    @objc private func didTapDoneButton(sender: UIButton) {
        self.doneRecordingDidPress(self, audioFilePath: curAudioPathStr!)
    }
    
    private func _updateTimeLabel(currentTime: NSTimeInterval) {
        let labelText = _formatTime(currentTime)
        timeLabel.text = labelText
    }
    
    private func _formatTime(time: NSTimeInterval) -> String {
        let second = (Int((time % 3600) % 60)).addLeadingZeroAsString()
        let minute = (Int((time % 3600) / 60)).addLeadingZeroAsString()
        let hour = (Int(time / 3600)).addLeadingZeroAsString()
        if hour == "00" {
            return "\(minute):\(second)"
        }
        return "\(hour):\(minute):\(second)"
    }
    
    private func setupUI() {
        let bounds = self.view.bounds
        
        // navbars, buttons
        _setupTopNavBar()
        _setupBottomNavBar()
        
        leftPanGesture = UIPanGestureRecognizer(target: self, action: #selector(self.didMoveLeftCropper(_:)))
        rightPanGesture = UIPanGestureRecognizer(target: self, action: #selector(self.didMoveRightCropper(_:)))
        
        print("setting up UI in Sound Recorder")
        self.view.addSubview(backgroundImageView)
        frostedView.frame = bounds
        self.view.addSubview(frostedView)
        
//        let margins = view.layoutMarginsGuide
        audioWaveContainerView.frame = CGRect(x: 0, y: 175, width: self.view.bounds.width, height: 200)
        audioWaveContainerView.translatesAutoresizingMaskIntoConstraints = false
        self.frostedView.addSubview(audioWaveContainerView)
        

//        audioWaveContainerView.widthAnchor.constraintEqualToConstant(self.view.bounds.width)
//        audioWaveContainerView.heightAnchor.constraintEqualToConstant(200)
//        audioWaveContainerView.topAnchor.constraintEqualToAnchor(topNavBar.layoutMarginsGuide.bottomAnchor).active = true
//        audioWaveContainerView.leadingAnchor.constraintEqualToAnchor(margins.leadingAnchor).active = true
//        audioWaveContainerView.trailingAnchor.constraintEqualToAnchor(margins.trailingAnchor).active = true
//        
        
        loadingActivityIndicator.frame = audioWaveContainerView.frame
        self.frostedView.addSubview(loadingActivityIndicator)
    }
    
    // MARK: add audioSiriWaveView to its container view
    private func _loadAudioSiriWaveView() {
        waveFormView.removeFromSuperview()
        
        if !audioWaveContainerView.subviews.contains(audioSiriWaveView) {
            audioWaveContainerView.addSubview(audioSiriWaveView)
            
            audioSiriWaveView.frame = CGRect(x: 0, y: 0, width: self.audioWaveContainerView.bounds.width, height: self.audioWaveContainerView.bounds.height)
        }
    }
    
    private func _loadWaveFormView() {
        audioSiriWaveView.removeFromSuperview()
        
        if !audioWaveContainerView.subviews.contains(waveFormView) {
            audioWaveContainerView.addSubview(waveFormView)
            waveFormView.frame = CGRect(x: 0, y: 0, width: self.audioWaveContainerView.bounds.width, height: self.audioWaveContainerView.bounds.height)
        }
    }
    
    private func _setupTopNavBar() {
        
        self.frostedView.addSubview(topNavBar)
        topNavBar.frame = CGRect(x: 0, y: 20, width: self.view.bounds.width, height: self.navbarHeight)
//        if #available(iOS 9.0, *) {
////            topNavBar.heightAnchor.constraintEqualToConstant(navbarHeight)
////            topNavBar.widthAnchor.constraintEqualToConstant(self.view.bounds.width)
//        } else {
//            // Fallback on earlier versions
//        }
        
        topNavBar.addSubview(cancelButton)
        topNavBar.addSubview(doneButton)
        
        timeLabel.text = "00:00"
        timeLabel.textColor = UIColor(white: 1, alpha: 0.9)
        clockIcon.tintColor = UIColor(white: 1, alpha: 0.9)

        if #available(iOS 9.0, *) {
            let stackView = UIStackView()
            stackView.axis = .Horizontal
            stackView.alignment = .Center
            stackView.distribution = .FillProportionally
            stackView.spacing = 7
            stackView.addArrangedSubview(timeLabel)
            stackView.addArrangedSubview(clockIcon)
            stackView.translatesAutoresizingMaskIntoConstraints = false
            
            topNavBar.addSubview(stackView)
            stackView.centerXAnchor.constraintEqualToAnchor(self.topNavBar.centerXAnchor).active = true
            stackView.centerYAnchor.constraintEqualToAnchor(self.topNavBar.centerYAnchor).active = true
        } else {
            timeLabel.center = topNavBar.center
            topNavBar.addSubview(timeLabel)
            // Fallback on earlier versions
        }
        
//        stackView.center = CGPointMake(self.topNavBar.frame.width/2, 5)
    }
    
    private func _setupBottomNavBar() {
        self.frostedView.addSubview(bottomNavBar)
        bottomNavBar.addSubview(micButton) // TODO: toggle recording also toggles the record/pause icon here!
        bottomNavBar.addSubview(stopButton)
        bottomNavBar.addSubview(playButton)
//        bottomNavBar.addSubview(undoTrimmingButton) // TODO: next release

        if allowCropping {
            bottomNavBar.addSubview(scissorButton)
        }
    }
    
    private func updateUIForOperation(mode: SwiftySoundMode) {
        switch mode {
        case .Idling:
            undoTrimmingButton.hidden = true
            
            stopButton.hidden = true
            //        stopButton.enabled = false
            playButton.hidden = false // alternate playButton and stopButton (for recording)
            playButton.enabled = curAudioPathStr != nil
            doneButton.enabled = curAudioPathStr != nil
            
            scissorButton.enabled = curAudioPathStr != nil
            scissorButton.tintColor = self.view.tintColor
            playButton.hidden = !stopButton.hidden // alternate playButton and stopButton (for recording)
            playButton.enabled = !playButton.hidden
            micButton.enabled = true
            clockIcon.tintColor = UIColor(white: 1, alpha: 0.9) // restore the original tint
            timeLabel.textColor = UIColor(white: 1, alpha: 0.9) // restore the original tint
            
            leftCropper.alpha = 0
            rightCropper.alpha = 0
        
        case .Recording:
            print("recording")
            _loadAudioSiriWaveView()
            undoTrimmingButton.hidden = true
            playButton.hidden = true
            stopButton.hidden = false
            stopButton.enabled = true
            scissorButton.enabled = false
            scissorButton.tintColor = self.view.tintColor
            doneButton.enabled = false
            
            leftCropper.alpha = 0
            rightCropper.alpha = 0
        case .Playing:
            print("playing...")
            _loadAudioSiriWaveView()
            undoTrimmingButton.hidden = true
            playButton.hidden = false
            stopButton.hidden = true
            scissorButton.enabled = true
            scissorButton.tintColor = self.view.tintColor
            micButton.enabled = false
            doneButton.enabled = curAudioPathStr != nil
            
            leftCropper.alpha = 0
            rightCropper.alpha = 0
        case .Cropping:
            print("Cropping....")
            _loadWaveFormView()
            
//            undoTrimmingButton.hidden = true // TODO: change to false in next release
//            undoTrimmingButton.enabled = true
            scissorButton.enabled = true
            scissorButton.tintColor = self.view.tintColor
            playButton.setBackgroundImage(playIcon, forState: .Normal) // restore the play icon
            stopButton.enabled = false
            micButton.enabled = false
            doneButton.enabled = true
        }
    }
    
    private func trimAudio(audioFileURL: NSURL, startTime: CGFloat, endTime: CGFloat) {
        
        guard allowCropping else { return }
        
        doneButton.enabled = false
        destroyPlayer()
        
        
        let audioAsset = AVAsset(URL: audioFileURL)
        let curAudioTrack = audioAsset.tracksWithMediaType(AVMediaTypeAudio).first
        
        if let exportSession = AVAssetExportSession(asset: audioAsset, presetName: AVAssetExportPresetAppleM4A) {
            
            let cmtDuration = CMTimeGetSeconds(audioAsset.duration)
            print("audio duration from CMT: \(cmtDuration)")
            let timeScale = curAudioTrack?.naturalTimeScale ?? 1
            print("time scale: \(timeScale)")
            let start = CMTimeMake(Int64(NSTimeInterval(startTime) * Double(timeScale)), timeScale)
            let end = CMTimeMake(Int64(NSTimeInterval(endTime) * Double(timeScale)), timeScale)
            let exportTimeRange = CMTimeRangeFromTimeToTime(start, end)
            
            // set up audio mix
            let exportAudioMix = AVMutableAudioMix()
            let exportAudioMixInputParams = AVMutableAudioMixInputParameters(track: curAudioTrack)
            exportAudioMix.inputParameters = NSArray(array: [exportAudioMixInputParams]) as! [AVAudioMixInputParameters]
            
            if fileManager.fileExistsAtPath(trimmedAudioURL.path!) {
                print("fileManager removing the existing trimmed audio")
                try! fileManager.removeItemAtURL(trimmedAudioURL)
            }
            
            exportSession.outputURL = NSURL(fileURLWithPath: trimmedAudioURL.path!)
            exportSession.outputFileType = AVFileTypeAppleM4A
            exportSession.timeRange = exportTimeRange
            exportSession.audioMix = exportAudioMix
            
            // execute the export of the trimmed audio
            exportSession.exportAsynchronouslyWithCompletionHandler({
                
                switch exportSession.status {
                case AVAssetExportSessionStatus.Completed:
                    
                    print("audio has been successfully trimed!")
                    let duration = Double(endTime - startTime)
                    self._updateUIOnCropFinish(exportSession.outputURL!, newAudioDuration: duration)
                    
                case AVAssetExportSessionStatus.Failed:
                    print("audio trimming failed!")
                    
                    if exportSession.status == AVAssetExportSessionStatus.Completed {
                        let uniqueStr = NSProcessInfo.processInfo().globallyUniqueString
                        let newAudioUrl = self.docDirectoryPath.URLByAppendingPathComponent("\(String(uniqueStr)).\(self.audioFileType)")
                        try! self.fileManager.moveItemAtURL(exportSession.outputURL!, toURL: newAudioUrl)

                        let duration = Double(endTime - startTime)
                        self._updateUIOnCropFinish(newAudioUrl, newAudioDuration: duration)
                    }
                    
                case AVAssetExportSessionStatus.Cancelled:
                    print("trimmed was cancelled")
                    
                default:
                    print("trimming and export completed!")
                }
            })
        }
    }
    
    // MARK: Update UI when cropping is finished
    private func _updateUIOnCropFinish(croppedFileURL: NSURL, newAudioDuration duration: NSTimeInterval) {
        
        self.waveFormView.audioURL = croppedFileURL
        runOnMainQueue {
            self.curAudioPathStr = croppedFileURL.path
            self.scissorButton.tintColor = self.view.tintColor
            self.audioDuration = duration
            self.doneButton.enabled = true
        }
    }
    
    
    // MARK: buttons
    
    private lazy var cancelButton: UIButton = {
        let button = UIButton(frame: CGRect(x: 0, y: 5, width: 70, height: 30))
        button.setTitle("Cancel", forState: .Normal)
        
        button.tintColor = UIColor(red: 255, green: 0, blue: 0, alpha: 0.9) // self.view.tintColor
        button.setTitleColor(UIColor(red: 255, green: 0, blue: 0, alpha: 0.9), forState: .Normal)
        button.setTitleColor(UIColor.grayColor(), forState: .Highlighted)
        
        button.addTarget(self, action: #selector(self.cancelRecordingDidPress(_:)), forControlEvents: .TouchUpInside)
        
        return button
    }()
    
    private lazy var doneButton: UIButton = {
        let button = UIButton(frame: CGRect(x: self.view.bounds.width-60, y: 5, width: 60, height: 30))
        button.setTitle("Done", forState: .Normal)
        button.enabled = false
        button.tintColor = UIColor(white: 1, alpha: 0.9)
        button.setTitleColor(UIColor(white: 1, alpha: 0.9), forState: .Normal)
        button.setTitleColor(UIColor.grayColor(), forState: .Highlighted)
        button.addTarget(self, action: #selector(self.didTapDoneButton), forControlEvents: .TouchUpInside)
        
        return button
    }()
    
    private let playIcon = AssetManager.getImage("ic_play_arrow").imageWithRenderingMode(.AlwaysTemplate)
    private lazy var playButton: UIButton = {
        let button = UIButton(type: .Custom)
        button.frame = CGRect(x: 0, y: 5, width: 35, height: 35)
        button.hidden = true // hidden default
        button.setBackgroundImage(self.playIcon, forState: .Normal)
        button.tintColor = self.view.tintColor
        button.setTitleColor(UIColor.redColor(), forState: .Highlighted) // ???
        button.contentMode = .ScaleAspectFit
        button.addTarget(self, action: #selector(self.togglePlayRecording), forControlEvents: .TouchUpInside)
        
        return button
    }()
    
    let stopIcon = AssetManager.getImage("ic_stop").imageWithRenderingMode(.AlwaysTemplate)
    private lazy var stopButton: UIButton = {
        let button = UIButton(type: .Custom)
        button.frame = CGRect(x: 0, y: 5, width: 35, height: 35)
        button.setBackgroundImage(self.stopIcon, forState: .Normal)
        button.contentMode = .ScaleAspectFit
        button.tintColor = UIColor.redColor()
        button.enabled = false // default to be disabled
        button.addTarget(self, action: #selector(self.stopRecording), forControlEvents: .TouchUpInside)
        
        return button
    }()
    
    // pauseButton and micButton alternate in the same position
    let pauseIcon = AssetManager.getImage("ic_pause").imageWithRenderingMode(.AlwaysTemplate)
//        UIImage(named: "ic_pause")?.imageWithRenderingMode(.AlwaysTemplate)
    
    
    let micIcon = AssetManager.getImage("ic_mic").imageWithRenderingMode(.AlwaysTemplate)
    // UIImage(named: "ic_mic")?.imageWithRenderingMode(.AlwaysTemplate)
    private lazy var micButton: UIButton = {
        let button = UIButton(type: .Custom)
        button.frame = CGRect(origin: CGPointMake(self.bottomNavBar.bounds.width/2 - 18, 5), size: CGSizeMake(35, 35))
//        button.center = self.bottomNavBar.center
        button.setBackgroundImage(self.micIcon, forState: .Normal)
        button.tintColor = UIColor(red: 255, green: 0, blue: 0, alpha: 0.9) // self.view.tintColor
        button.setTitleColor(UIColor(red: 255, green: 0, blue: 0, alpha: 0.9), forState: .Normal)
        button.contentMode = .ScaleAspectFit
        button.addTarget(self, action: #selector(self.toggleRecording), forControlEvents: .TouchUpInside)
        
        return button
    }()
    
    let scissorIcon = AssetManager.getImage("ic_content_cut").imageWithRenderingMode(.AlwaysTemplate)
    private lazy var scissorButton: UIButton = {
        let button = UIButton(type: .Custom)
        button.frame = CGRect(x: self.view.bounds.width - 45, y: 5, width: 35, height: 35)
        button.tintColor = self.view.tintColor
        button.enabled = false
        button.setTitleColor(self.view.tintColor, forState: .Normal)
        button.setTitleColor(UIColor.grayColor(), forState: .Highlighted)
        
        button.setBackgroundImage(self.scissorIcon, forState: .Normal)
        button.contentMode = .ScaleAspectFit
        button.addTarget(self, action: #selector(self.beginAudioCropMode), forControlEvents: .TouchUpInside) // TODO:
        
        return button
    }()
    
    let undoIcon = AssetManager.getImage("ic_undo").imageWithRenderingMode(.AlwaysTemplate)
//        UIImage(named: "ic_undo")?.imageWithRenderingMode(.AlwaysTemplate)
    private lazy var undoTrimmingButton: UIButton = {
        let button = UIButton(type: .Custom)
        button.frame = CGRect(origin: CGPointZero, size: CGSizeMake(35, 35)) // TODO: coordinate
        button.tintColor = self.view.tintColor
        button.enabled = false
        button.setTitleColor(self.view.tintColor, forState: .Normal)
        button.setTitleColor(UIColor.grayColor(), forState: .Highlighted)
        button.hidden = true // TODO: work on this undo button in next release; hidden temporarily
        button.setBackgroundImage(self.undoIcon, forState: .Normal)
        button.contentMode = .ScaleAspectFit
//        button.addTarget(self, action: #selector(self.undoTrimming), forControlEvents: .TouchUpInside)
        return button
    }()
    
    public lazy var docDirectoryPath: NSURL = {
        let docPath = self.fileManager.URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask).first! as NSURL
        
        return docPath
    }()
    
    private lazy var originalRecordedAudioURL: NSURL = {
        let fileUrl = self.docDirectoryPath.URLByAppendingPathComponent("\(Configuration.originalRecordingFileName)\(self.audioFileType)")
        
        return fileUrl
    }()
    
    private lazy var trimmedAudioURL: NSURL = {
        let fileUrl = self.docDirectoryPath.URLByAppendingPathComponent("\(Configuration.trimmedRecordingFileName)\(self.audioFileType)")
        
        return fileUrl
    }()
    
    private lazy var audioWaveContainerView: UIView = {
        let view = UIView() // frame: CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 200)
//        view.clipsToBounds = true
        view.backgroundColor = UIColor.clearColor() // UIColor.whiteColor()
        view.center = self.view.center
        
        return view
    }()
    
    let clockIcon = UIImageView(image: AssetManager.getImage("ic_av_timer").imageWithRenderingMode(.AlwaysTemplate))
    private lazy var timeLabel: UILabel = {
        let label = UILabel()
//        label.frame = CGRect(origin: CGPointZero, size: CGSizeMake(130, 30))
//        label.center = self.topNavBar.center
//        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var loadingActivityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(activityIndicatorStyle: .WhiteLarge)
        indicator.color = UIColor.lightGrayColor()
        indicator.frame = self.audioWaveContainerView.frame // CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 200)
        indicator.center = self.audioWaveContainerView.center
        indicator.autoresizingMask = [.FlexibleTopMargin, .FlexibleBottomMargin, .FlexibleLeftMargin, .FlexibleRightMargin]
        indicator.hidden = true
        
        return indicator
    }()
    
    private lazy var audioSiriWaveView: SCSiriWaveformView = {
        let flowView = SCSiriWaveformView(frame: CGRect(x: 0, y: 0, width: self.audioWaveContainerView.bounds.width, height: self.audioWaveContainerView.bounds.height))
        flowView.translatesAutoresizingMaskIntoConstraints = false
        flowView.alpha = 1.0
        flowView.backgroundColor = UIColor.clearColor()
//        flowView.frame = self.audioWaveContainerView.bounds
        flowView.center = self.audioWaveContainerView.center
        flowView.clipsToBounds = false
        flowView.primaryWaveLineWidth = 3.0
        flowView.secondaryWaveLineWidth = 1.0
        flowView.waveColor = Configuration.defaultBlueTintColor
        
        return flowView
    }()
    
    private lazy var waveFormView: FDWaveformView = {
        let formView = FDWaveformView()
        formView.translatesAutoresizingMaskIntoConstraints = false
        formView.backgroundColor = UIColor.grayColor()
        formView.hidden = true
        formView.center = self.audioWaveContainerView.center
        formView.wavesColor = UIColor.whiteColor() // self.waveTintColor
        formView.progressColor = self.waveHighlightedTintColor
        formView.doesAllowScroll = false
        formView.doesAllowScrubbing = false
        formView.doesAllowStretch = false
        formView.progressSamples = 10000
        formView.delegate = self
        
        return formView
    }()
    
    private lazy var backgroundImageView: UIImageView = {
        let imageView = UIImageView(image: Configuration.milkyWayImage)
        imageView.frame = self.view.bounds
        imageView.contentMode = .ScaleToFill
        
        return imageView
    }()
    
    private lazy var leftCropper: Cropper = {
        let cropper = Cropper(cropperType: .Left, lineThickness: 3, lineColor: UIColor.redColor())
        cropper.translatesAutoresizingMaskIntoConstraints = false
        cropper.addGestureRecognizer(self.leftPanGesture)
        cropper.alpha = 0
        
        return cropper
    }()
    
    private lazy var rightCropper: Cropper = {
        let cropper = Cropper(cropperType: .Right, lineThickness: 3, lineColor: UIColor.redColor())
        cropper.translatesAutoresizingMaskIntoConstraints = false
        cropper.addGestureRecognizer(self.rightPanGesture)
        cropper.alpha = 0
        
        return cropper
    }()
    
    private lazy var topNavBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = UIColor.grayColor()
        bar.layer.borderWidth = 0.5
        bar.layer.borderColor = UIColor(white: 1, alpha: 0.8).CGColor
//        bar.translatesAutoresizingMaskIntoConstraints = false
        
        return bar
    }()
    
    private lazy var bottomNavBar: UIView = {
        let bottomBar = UIView(frame: CGRect(x: 0, y: self.view.bounds.height - self.navbarHeight, width: self.view.bounds.width, height: self.navbarHeight))
        bottomBar.backgroundColor = UIColor.grayColor()
        bottomBar.layer.borderWidth = 0.5
        bottomBar.layer.borderColor = UIColor(white: 1, alpha: 0.8).CGColor
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        
        return bottomBar
    }()
    
    private let recorderSettings = [AVSampleRateKey : NSNumber(float: Float(44100.0)),
                                    AVFormatIDKey : NSNumber(int: Int32(kAudioFormatMPEG4AAC)),
                                    AVNumberOfChannelsKey : NSNumber(int: 2),
                                    AVEncoderAudioQualityKey : NSNumber(int: Int32(AVAudioQuality.Medium.rawValue))]
}

extension SwiftySoundRecorder: SwiftySoundRecorderDelegate {
    public func cancelRecordingDidPress(soundRecorder: SwiftySoundRecorder) {
        delegate?.cancelRecordingDidPress(self)
    }
    
    public func doneRecordingDidPress(soundRecorder: SwiftySoundRecorder, audioFilePath: String) {
        delegate?.doneRecordingDidPress(self, audioFilePath: audioFilePath)
    }
}

// Pan Gestures here
extension SwiftySoundRecorder {
    
    @objc func didMoveLeftCropper(panRecognizer: UIPanGestureRecognizer) {
        
        var panBeginPoint: CGPoint = CGPointZero // panRecognizer.translationInView(audioWaveContainerView) // leftCropper.frame.origin
        var beginCenter: CGPoint = CGPointZero
        //        var curPanPoint = CGPointZero // current pan point
        switch panRecognizer.state {
        case UIGestureRecognizerState.Began:
            panBeginPoint = panRecognizer.translationInView(audioWaveContainerView)
            beginCenter = leftCropper.center

            destroyPlayer()
            audioRecorder?.stop()
            
        case UIGestureRecognizerState.Changed:
            
            let curPanPoint = panRecognizer.translationInView(audioWaveContainerView)
            // Left Margin
            var pointX: CGFloat = max(waveFormView.frame.minX, beginCenter.x + curPanPoint.x - panBeginPoint.x)
            pointX = min(rightCropper.frame.minX, pointX)
            leftCropper.center = CGPointMake(pointX, beginCenter.y + leftCropper.bounds.height / 2) // + 1/2 height ?
            
            // update crop time label
            let leftPercentage = CGFloat((leftCropper.center.x - (leftCropper.frame.width / 2)) / waveFormView.frame.size.width)
            let curPlayerDuration = audioPlayer?.duration ?? audioDuration
            leftCropper.cropTime = leftPercentage * CGFloat(curPlayerDuration)
            let curPlayedPercentage: Double = Double(leftCropper.cropTime) / curPlayerDuration

            waveFormView.progressSamples = Int(Double(waveFormView.totalSamples) * curPlayedPercentage)
            
            if leftCropper.cropTime > 0 {
                isCroppingEnabled = true
                scissorButton.tintColor = UIColor.redColor()
            } else {
                isCroppingEnabled = false
                scissorButton.tintColor = self.view.tintColor
            }
            
            
        default:
            // Ended as default
            panBeginPoint = CGPointZero
            beginCenter = CGPointZero
        }
    }
    
    @objc func didMoveRightCropper(panRecognizer: UIPanGestureRecognizer) {
        NSLog("Not implemented yet")
        /*
        var panBeginPoint: CGPoint = CGPointZero
        // CGPointMake(audioWaveContainerView.bounds.width - rightCropper.width, 0) // panRecognizer.translationInView(audioWaveContainerView)
            // CGPointMake(rightCropper.frame.minX, rightCropper.frame.minY) // panRecognizer.translationInView(audioWaveContainerView) // leftCropper.frame.origin
//        print("panBeginPoint: \(panBeginPoint.x), \(panBeginPoint.y)")
        var beginCenter: CGPoint = rightCropper.center
        
        switch panRecognizer.state {
        case UIGestureRecognizerState.Began:
            panBeginPoint = panRecognizer.translationInView(audioWaveContainerView)
            beginCenter = rightCropper.center
            
            destroyPlayer()
            audioRecorder?.stop()
            
        case UIGestureRecognizerState.Changed:
            
            let curPanPoint = panRecognizer.translationInView(audioWaveContainerView)
            print("curPanPoint.x: \(curPanPoint.x), leftCropper.maxX: \(leftCropper.frame.maxX)")
//            guard curPanPoint.x > leftCropper.frame.maxX else { return } // prevent right cropper from moving to the left of the leftCropper
            // Right Margin
            var pointX: CGFloat = min(waveFormView.frame.maxX, beginCenter.x + curPanPoint.x - panBeginPoint.x)
            pointX = max(rightCropper.frame.maxX, pointX)
            rightCropper.center = CGPointMake(pointX, beginCenter.y + rightCropper.bounds.height / 2)
            
            // update crop time label
            let rightPercentage = CGFloat((rightCropper.center.x - (rightCropper.frame.width / 2)) / waveFormView.frame.size.width)
            let curPlayerDuration = audioPlayer?.duration ?? audioDuration
            rightCropper.cropTime = rightPercentage * CGFloat(curPlayerDuration)
            
            // update the progress, same as in didMoveLeft(_:)
            let curPlayedPercentage: Double = Double(leftCropper.cropTime) / curPlayerDuration
            waveFormView.progressSamples = Int(Double(waveFormView.totalSamples) * curPlayedPercentage)
            
            // at least 2 seconds of audio exist after cropping
            if leftCropper.cropTime > 0 && (rightCropper.cropTime - leftCropper.cropTime) >= 2 {
                isCroppingEnabled = true
                scissorButton.tintColor = UIColor.redColor()
            } else {
                isCroppingEnabled = false
                scissorButton.tintColor = self.view.tintColor
            }
            
        case UIGestureRecognizerState.Failed:
            print("failed to move")
            // Ended as default
            panBeginPoint = CGPointZero
            beginCenter = CGPointZero
            
        default:
            // Ended as default
            panBeginPoint = CGPointZero
            beginCenter = CGPointZero
        }
        */
        
    }
}

extension SwiftySoundRecorder: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(player: AVAudioPlayer, successfully flag: Bool) {
        audioTimer.invalidate()
        playButton.setBackgroundImage(self.playIcon, forState: .Normal)
        audioDuration = player.duration
        print("recorded audio duration: \(audioDuration) after playing")
        
        if operationMode == .Cropping {
            return
        }
        
        audioPlayer = nil
        self.operationMode = .Idling
    }
    
    public func audioPlayerBeginInterruption(player: AVAudioPlayer) {
        print("audio player began to be interrupted")
    }
    
    public func audioPlayerEndInterruption(player: AVAudioPlayer) {
        print("audio player ended interruption")
    }
}

extension SwiftySoundRecorder: AVAudioRecorderDelegate {
    public func audioRecorderDidFinishRecording(recorder: AVAudioRecorder, successfully flag: Bool) {
        //        audioDuration = floor(recorder.currentTime / 60)
        curAudioPathStr = recorder.url.path
        audioTimer.invalidate()
        
        audioRecorder = nil
        micButton.setBackgroundImage(micIcon, forState: .Normal)
        
        self.operationMode = .Idling
    }
    
    private func _toggleActivityIndicator(toShow isToBeShown: Bool) {
        if isToBeShown {
            
            self.loadingActivityIndicator.superview!.bringSubviewToFront(self.loadingActivityIndicator)
            self.loadingActivityIndicator.hidden = false
            self.loadingActivityIndicator.startAnimating()
        } else {
            self.loadingActivityIndicator.stopAnimating()
            self.loadingActivityIndicator.hidden = true
        }
    }
    
    // MARK: execute the block callback on the main thread
    private func runOnMainQueue(callback blockFunc: () -> Void) {
        NSOperationQueue.mainQueue().addOperationWithBlock {
            blockFunc()
        }
    }
}

extension SwiftySoundRecorder: FDWaveformViewDelegate {
    public func waveformViewWillRender(waveformView: FDWaveformView!) {
       
        runOnMainQueue { 
            UIView.animateWithDuration(0.5, animations: {
                self.audioWaveContainerView.alpha = 0.0
                self.waveFormView.hidden = true
                self._toggleActivityIndicator(toShow: true)
            })
        }
    }
    
    public func waveformViewDidRender(waveformView: FDWaveformView!) {
        
        UIView.animateWithDuration(3) {
            self.audioWaveContainerView.alpha = 1.0
            self._toggleActivityIndicator(toShow: false)
            self.waveFormView.hidden = false
            self._loadCroppers()
        }
    }
    
    public func waveformDidBeginPanning(waveformView: FDWaveformView!) {
        print("wave form begin panning")
    }
    
    public func waveformDidEndPanning(waveformView: FDWaveformView!) {
        print("wave form ended panning")
    }
}

extension SwiftySoundRecorder: NSFileManagerDelegate {
    
    public func fileManager(fileManager: NSFileManager, shouldMoveItemAtURL srcURL: NSURL, toURL dstURL: NSURL) -> Bool {
        return true
    }
    
    public func fileManager(fileManager: NSFileManager, shouldRemoveItemAtURL URL: NSURL) -> Bool {
        return true
    }
}