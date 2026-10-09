import SwiftUI

struct Game2048View: View {
    @AppStorage("game2048_high_score") private var highScore: Int = 0

    @State private var board: [[Int]] = Array(repeating: Array(repeating: 0, count: 4), count: 4)
    @State private var score: Int = 0
    @State private var isGameOver: Bool = false
    @State private var hasSwipedInDrag: Bool = false

    var body: some View {
        ZStack {
            // Arrière-plan beige classique du jeu 2048
            Color(red: 0.98, green: 0.97, blue: 0.93)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Header (Titre + Scores)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("2048")
                            .font(.system(size: 48, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))
                        Text("Rejoignez les tuiles !")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.55, green: 0.50, blue: 0.47))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        scoreBox(title: "SCORE", value: score)
                        scoreBox(title: "MEILLEUR", value: max(score, highScore))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Barre d'action
                HStack {
                    Spacer()
                    Button {
                        startNewGame()
                    } label: {
                        Text("Nouvelle partie")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.56, green: 0.48, blue: 0.40))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // Grille 4x4
                ZStack {
                    // Conteneur de grille
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.73, green: 0.68, blue: 0.63))
                        .aspectRatio(1.0, contentMode: .fit)

                    // Cellules
                    GeometryReader { geo in
                        let spacing: CGFloat = 10
                        let totalSpacing = spacing * 5
                        let tileSize = (geo.size.width - totalSpacing) / 4

                        VStack(spacing: spacing) {
                            ForEach(0..<4, id: \.self) { row in
                                HStack(spacing: spacing) {
                                    ForEach(0..<4, id: \.self) { col in
                                        tileView(value: board[row][col], size: tileSize)
                                    }
                                }
                            }
                        }
                        .padding(spacing)
                    }
                    .aspectRatio(1.0, contentMode: .fit)

                    // Overlay Game Over
                    if isGameOver {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.85))
                            .aspectRatio(1.0, contentMode: .fit)

                        VStack(spacing: 14) {
                            Text("Partie terminée !")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))

                            Button {
                                startNewGame()
                            } label: {
                                Text("Rejouer")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 10)
                                    .background(Color(red: 0.56, green: 0.48, blue: 0.40))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { gesture in
                            guard !hasSwipedInDrag && !isGameOver else { return }
                            let transX = gesture.translation.width
                            let transY = gesture.translation.height

                            if abs(transX) > abs(transY) {
                                if transX > 25 {
                                    hasSwipedInDrag = true
                                    move(.right)
                                } else if transX < -25 {
                                    hasSwipedInDrag = true
                                    move(.left)
                                }
                            } else {
                                if transY > 25 {
                                    hasSwipedInDrag = true
                                    move(.down)
                                } else if transY < -25 {
                                    hasSwipedInDrag = true
                                    move(.up)
                                }
                            }
                        }
                        .onEnded { _ in
                            hasSwipedInDrag = false
                        }
                )

                Spacer()

                Text("Glissez dans n'importe quelle direction pour fusionner")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.62, green: 0.57, blue: 0.53))
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            if isBoardEmpty {
                startNewGame()
            }
        }
    }

    // MARK: - Subviews

    private func scoreBox(title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.93, green: 0.89, blue: 0.85))
            Text("\(value)")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.73, green: 0.68, blue: 0.63))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tileView(value: Int, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tileBackgroundColor(value: value))
                .frame(width: size, height: size)

            if value > 0 {
                Text("\(value)")
                    .font(.system(
                        size: value > 512 ? size * 0.28 : (value > 64 ? size * 0.35 : size * 0.42),
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(tileTextColor(value: value))
                    .minimumScaleFactor(0.5)
            }
        }
    }

    // MARK: - Game Logic

    private enum MoveDirection {
        case up, down, left, right
    }

    private var isBoardEmpty: Bool {
        for row in board {
            for val in row where val != 0 {
                return false
            }
        }
        return true
    }

    private func startNewGame() {
        board = Array(repeating: Array(repeating: 0, count: 4), count: 4)
        score = 0
        isGameOver = false
        spawnTile()
        spawnTile()
    }

    private func move(_ direction: MoveDirection) {
        var originalBoard = board
        var gainedPoints = 0

        switch direction {
        case .left:
            for r in 0..<4 {
                let res = mergeRow(board[r])
                board[r] = res.row
                gainedPoints += res.score
            }
        case .right:
            for r in 0..<4 {
                let reversed = Array(board[r].reversed())
                let res = mergeRow(reversed)
                board[r] = Array(res.row.reversed())
                gainedPoints += res.score
            }
        case .up:
            for c in 0..<4 {
                var col = [board[0][c], board[1][c], board[2][c], board[3][c]]
                let res = mergeRow(col)
                for r in 0..<4 { board[r][c] = res.row[r] }
                gainedPoints += res.score
            }
        case .down:
            for c in 0..<4 {
                var col = [board[3][c], board[2][c], board[1][c], board[0][c]]
                let res = mergeRow(col)
                for r in 0..<4 { board[3 - r][c] = res.row[r] }
                gainedPoints += res.score
            }
        }

        if board != originalBoard {
            score += gainedPoints
            if score > highScore {
                highScore = score
            }
            spawnTile()
            if !canMakeAnyMove() {
                isGameOver = true
            }
        }
    }

    private func mergeRow(_ row: [Int]) -> (row: [Int], score: Int) {
        var nonZeros = row.filter { $0 != 0 }
        var result: [Int] = []
        var scoreGained = 0
        var i = 0

        while i < nonZeros.count {
            if i + 1 < nonZeros.count && nonZeros[i] == nonZeros[i + 1] {
                let merged = nonZeros[i] * 2
                result.append(merged)
                scoreGained += merged
                i += 2
            } else {
                result.append(nonZeros[i])
                i += 1
            }
        }

        while result.count < 4 {
            result.append(0)
        }

        return (result, scoreGained)
    }

    private func spawnTile() {
        var emptyCoords: [(Int, Int)] = []
        for r in 0..<4 {
            for c in 0..<4 {
                if board[r][c] == 0 {
                    emptyCoords.append((r, c))
                }
            }
        }

        guard let randomCoord = emptyCoords.randomElement() else { return }
        // 90% chance of 2, 10% chance of 4
        let newValue = (Double.random(in: 0...1) < 0.9) ? 2 : 4
        board[randomCoord.0][randomCoord.1] = newValue
    }

    private func canMakeAnyMove() -> Bool {
        for r in 0..<4 {
            for c in 0..<4 {
                if board[r][c] == 0 { return true }
                if r + 1 < 4 && board[r][c] == board[r + 1][c] { return true }
                if c + 1 < 4 && board[r][c] == board[r][c + 1] { return true }
            }
        }
        return false
    }

    // MARK: - Palette Colors

    private func tileBackgroundColor(value: Int) -> Color {
        switch value {
        case 0:
            return Color(red: 0.80, green: 0.75, blue: 0.71)
        case 2:
            return Color(red: 0.93, green: 0.89, blue: 0.85)
        case 4:
            return Color(red: 0.93, green: 0.88, blue: 0.78)
        case 8:
            return Color(red: 0.95, green: 0.69, blue: 0.47)
        case 16:
            return Color(red: 0.96, green: 0.58, blue: 0.39)
        case 32:
            return Color(red: 0.96, green: 0.49, blue: 0.37)
        case 64:
            return Color(red: 0.96, green: 0.37, blue: 0.23)
        case 128:
            return Color(red: 0.93, green: 0.81, blue: 0.45)
        case 256:
            return Color(red: 0.93, green: 0.80, blue: 0.38)
        case 512:
            return Color(red: 0.93, green: 0.78, blue: 0.31)
        case 1024:
            return Color(red: 0.93, green: 0.77, blue: 0.25)
        case 2048:
            return Color(red: 0.93, green: 0.76, blue: 0.18)
        default:
            return Color(red: 0.24, green: 0.23, blue: 0.20)
        }
    }

    private func tileTextColor(value: Int) -> Color {
        if value <= 4 {
            return Color(red: 0.47, green: 0.43, blue: 0.40)
        } else {
            return Color(red: 0.98, green: 0.96, blue: 0.95)
        }
    }
}

#Preview {
    Game2048View()
}
