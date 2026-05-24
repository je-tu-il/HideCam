//
//  ContentView.swift
//  StealthRecorder
//
//  Created by Rork on May 23, 2026.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var cameraManager: CameraManager = CameraManager()
    private let shouldShowSettingsAtLaunch: Bool

    init() {
        shouldShowSettingsAtLaunch = AVAudioSession.sharedInstance().outputVolume == 1.0
    }

    var body: some View {
        Group {
            if shouldShowSettingsAtLaunch {
                SettingsView()
            } else {
                Color.black
                    .edgesIgnoringSafeArea(.all)
                    .onAppear {
                        cameraManager.startFromCurrentSystemVolume()
                    }
            }
        }
    }
}

#Preview {
    ContentView()
}
