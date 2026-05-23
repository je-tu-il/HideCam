//
//  ContentView.swift
//  StealthRecorder
//
//  Created by Rork on May 23, 2026.
//

import SwiftUI

struct ContentView: View {
    @State private var cameraManager: CameraManager = CameraManager()

    var body: some View {
        Color.black
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                cameraManager.startFromCurrentSystemVolume()
            }
    }
}

#Preview {
    ContentView()
}
