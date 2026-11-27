package com.droply.android.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Vector icons matching the Apple SF Symbols used in the macOS Droply app.
 */
object MacIcons {
    private val ink = SolidColor(Color.Black)

    private inline fun icon(
        name: String,
        block: ImageVector.Builder.() -> Unit
    ): ImageVector = ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f
    ).apply(block).build()

    private inline fun ImageVector.Builder.strokePath(
        lineWidth: Float = 1.9f,
        cap: StrokeCap = StrokeCap.Round,
        join: StrokeJoin = StrokeJoin.Round,
        block: PathBuilder.() -> Unit
    ) {
        path(
            fill = null,
            stroke = ink,
            strokeLineWidth = lineWidth,
            strokeLineCap = cap,
            strokeLineJoin = join,
            pathBuilder = block
        )
    }

    private inline fun ImageVector.Builder.fillPath(
        fillType: PathFillType = PathFillType.NonZero,
        block: PathBuilder.() -> Unit
    ) {
        path(
            fill = ink,
            pathFillType = fillType,
            pathBuilder = block
        )
    }

    private fun PathBuilder.circle(cx: Float, cy: Float, r: Float) {
        moveTo(cx + r, cy)
        arcTo(r, r, 0f, isMoreThanHalf = true, isPositiveArc = true, cx - r, cy)
        arcTo(r, r, 0f, isMoreThanHalf = true, isPositiveArc = true, cx + r, cy)
        close()
    }

    private fun PathBuilder.roundedRect(left: Float, top: Float, right: Float, bottom: Float, r: Float) {
        moveTo(left + r, top)
        lineTo(right - r, top)
        quadTo(right, top, right, top + r)
        lineTo(right, bottom - r)
        quadTo(right, bottom, right - r, bottom)
        lineTo(left + r, bottom)
        quadTo(left, bottom, left, bottom - r)
        lineTo(left, top + r)
        quadTo(left, top, left + r, top)
        close()
    }

    // SF "wifi"
    val Wifi: ImageVector by lazy {
        icon("MacWifi") {
            strokePath(lineWidth = 2.15f) {
                moveTo(3.1f, 9.6f)
                arcTo(12.6f, 12.6f, 0f, isMoreThanHalf = false, isPositiveArc = true, 20.9f, 9.6f)
                moveTo(5.9f, 12.4f)
                arcTo(8.6f, 8.6f, 0f, isMoreThanHalf = false, isPositiveArc = true, 18.1f, 12.4f)
                moveTo(8.75f, 15.25f)
                arcTo(4.6f, 4.6f, 0f, isMoreThanHalf = false, isPositiveArc = true, 15.25f, 15.25f)
            }
            fillPath {
                circle(12f, 18.4f, 1.45f)
            }
        }
    }

    // SF "sun.max.fill"
    val SunMaxFill: ImageVector by lazy {
        icon("MacSunMaxFill") {
            fillPath {
                circle(12f, 12f, 4.9f)
            }
            strokePath(lineWidth = 1.95f) {
                moveTo(12f, 2.3f); lineTo(12f, 4.7f)
                moveTo(12f, 19.3f); lineTo(12f, 21.7f)
                moveTo(2.3f, 12f); lineTo(4.7f, 12f)
                moveTo(19.3f, 12f); lineTo(21.7f, 12f)
                moveTo(5.14f, 5.14f); lineTo(6.84f, 6.84f)
                moveTo(17.16f, 17.16f); lineTo(18.86f, 18.86f)
                moveTo(18.86f, 5.14f); lineTo(17.16f, 6.84f)
                moveTo(6.84f, 17.16f); lineTo(5.14f, 18.86f)
            }
        }
    }

    // SF "moon.fill"
    val MoonFill: ImageVector by lazy {
        icon("MacMoonFill") {
            fillPath {
                moveTo(19.6f, 14.35f)
                arcTo(8.1f, 8.1f, 0f, isMoreThanHalf = false, isPositiveArc = true, 9.65f, 4.4f)
                arcTo(8.35f, 8.35f, 0f, isMoreThanHalf = true, isPositiveArc = false, 19.6f, 14.35f)
                close()
            }
        }
    }

    // SF "xmark.circle"
    val XmarkCircle: ImageVector by lazy {
        icon("MacXmarkCircle") {
            strokePath(lineWidth = 1.85f) {
                circle(12f, 12f, 9.2f)
                moveTo(8.9f, 8.9f); lineTo(15.1f, 15.1f)
                moveTo(15.1f, 8.9f); lineTo(8.9f, 15.1f)
            }
        }
    }

    // SF "xmark"
    val Xmark: ImageVector by lazy {
        icon("MacXmark") {
            strokePath(lineWidth = 2.15f) {
                moveTo(6.2f, 6.2f); lineTo(17.8f, 17.8f)
                moveTo(17.8f, 6.2f); lineTo(6.2f, 17.8f)
            }
        }
    }

    // SF "qrcode"
    val QrCode: ImageVector by lazy {
        icon("MacQrCode") {
            strokePath(lineWidth = 1.75f, join = StrokeJoin.Round) {
                roundedRect(3.2f, 3.2f, 9.6f, 9.6f, 1.0f)
                roundedRect(14.4f, 3.2f, 20.8f, 9.6f, 1.0f)
                roundedRect(3.2f, 14.4f, 9.6f, 20.8f, 1.0f)
            }
            fillPath {
                roundedRect(5.2f, 5.2f, 7.6f, 7.6f, 0.4f)
                roundedRect(16.4f, 5.2f, 18.8f, 7.6f, 0.4f)
                roundedRect(5.2f, 16.4f, 7.6f, 18.8f, 0.4f)
                roundedRect(14.0f, 14.0f, 16.4f, 16.4f, 0.4f)
                roundedRect(18.6f, 14.0f, 21.0f, 16.4f, 0.4f)
                roundedRect(16.3f, 16.3f, 18.7f, 18.7f, 0.4f)
                roundedRect(14.0f, 18.6f, 16.4f, 21.0f, 0.4f)
                roundedRect(18.6f, 18.6f, 21.0f, 21.0f, 0.4f)
            }
        }
    }

    // SF "doc.badge.plus"
    val DocBadgePlus: ImageVector by lazy {
        icon("MacDocBadgePlus") {
            strokePath(lineWidth = 1.85f) {
                // Page body leaving clean corner notch for '+'
                moveTo(12.2f, 20.6f)
                lineTo(6.4f, 20.6f)
                quadTo(4.8f, 20.6f, 4.8f, 19.0f)
                lineTo(4.8f, 4.6f)
                quadTo(4.8f, 3.0f, 6.4f, 3.0f)
                lineTo(13.2f, 3.0f)
                lineTo(18.2f, 8.0f)
                lineTo(18.2f, 12.2f)
                // Folded dog-ear
                moveTo(13.2f, 3.2f)
                lineTo(13.2f, 7.2f)
                quadTo(13.2f, 8.0f, 14.0f, 8.0f)
                lineTo(18.0f, 8.0f)
                // Bold plus badge bottom-right
                moveTo(17.5f, 14.5f); lineTo(17.5f, 20.9f)
                moveTo(14.3f, 17.7f); lineTo(20.7f, 17.7f)
            }
        }
    }

    // SF "folder.badge.plus"
    val FolderBadgePlus: ImageVector by lazy {
        icon("MacFolderBadgePlus") {
            strokePath(lineWidth = 1.85f) {
                // Folder silhouette leaving bottom-right open for '+'
                moveTo(12.2f, 19.2f)
                lineTo(4.6f, 19.2f)
                quadTo(2.8f, 19.2f, 2.8f, 17.4f)
                lineTo(2.8f, 6.2f)
                quadTo(2.8f, 4.6f, 4.5f, 4.6f)
                lineTo(8.5f, 4.6f)
                quadTo(9.4f, 4.6f, 10.0f, 5.4f)
                lineTo(11.1f, 6.8f)
                lineTo(19.4f, 6.8f)
                quadTo(21.2f, 6.8f, 21.2f, 8.6f)
                lineTo(21.2f, 11.8f)
                // Plus badge bottom-right
                moveTo(17.8f, 14.2f); lineTo(17.8f, 20.6f)
                moveTo(14.6f, 17.4f); lineTo(21.0f, 17.4f)
            }
        }
    }

    // SF "text.badge.plus"
    val TextBadgePlus: ImageVector by lazy {
        icon("MacTextBadgePlus") {
            strokePath(lineWidth = 2.0f) {
                moveTo(4.0f, 6.2f); lineTo(18.2f, 6.2f)
                moveTo(4.0f, 10.2f); lineTo(20.0f, 10.2f)
                moveTo(4.0f, 14.2f); lineTo(12.4f, 14.2f)
                moveTo(4.0f, 18.2f); lineTo(11.2f, 18.2f)
                // Plus badge bottom-right
                moveTo(17.6f, 14.0f); lineTo(17.6f, 20.4f)
                moveTo(14.4f, 17.2f); lineTo(20.8f, 17.2f)
            }
        }
    }

    // SF "trash"
    val Trash: ImageVector by lazy {
        icon("MacTrash") {
            strokePath(lineWidth = 1.75f) {
                moveTo(4.2f, 6.2f); lineTo(19.8f, 6.2f)
                moveTo(8.8f, 6.2f)
                lineTo(9.4f, 3.8f)
                quadTo(9.6f, 3.1f, 10.3f, 3.1f)
                lineTo(13.7f, 3.1f)
                quadTo(14.4f, 3.1f, 14.6f, 3.8f)
                lineTo(15.2f, 6.2f)
                moveTo(6.2f, 6.2f)
                lineTo(7.1f, 19.1f)
                quadTo(7.2f, 20.6f, 8.7f, 20.6f)
                lineTo(15.3f, 20.6f)
                quadTo(16.8f, 20.6f, 16.9f, 19.1f)
                lineTo(17.8f, 6.2f)
                moveTo(10.2f, 10.0f); lineTo(10.5f, 17.0f)
                moveTo(13.8f, 10.0f); lineTo(13.5f, 17.0f)
            }
        }
    }

    // SF "paperplane"
    val Paperplane: ImageVector by lazy {
        icon("MacPaperplane") {
            strokePath(lineWidth = 1.65f) {
                moveTo(20.8f, 3.2f)
                lineTo(3.2f, 10.4f)
                lineTo(10.9f, 13.1f)
                lineTo(13.6f, 20.8f)
                close()
                moveTo(10.9f, 13.1f)
                lineTo(20.8f, 3.2f)
            }
        }
    }

    // SF "tray.and.arrow.down"
    val TrayAndArrowDown: ImageVector by lazy {
        icon("MacTrayAndArrowDown") {
            strokePath(lineWidth = 1.7f) {
                // Downward arrow
                moveTo(12f, 3.2f); lineTo(12f, 13.8f)
                moveTo(8.4f, 10.3f); lineTo(12f, 13.9f); lineTo(15.6f, 10.3f)
                // Inbox tray
                moveTo(7.2f, 9.6f)
                lineTo(5.6f, 9.6f)
                quadTo(4.4f, 9.6f, 4.0f, 10.7f)
                lineTo(2.9f, 14.6f)
                lineTo(2.9f, 19.0f)
                quadTo(2.9f, 20.5f, 4.4f, 20.5f)
                lineTo(19.6f, 20.5f)
                quadTo(21.1f, 20.5f, 21.1f, 19.0f)
                lineTo(21.1f, 14.6f)
                lineTo(20.0f, 10.7f)
                quadTo(19.6f, 9.6f, 18.4f, 9.6f)
                lineTo(16.8f, 9.6f)
                // Inner tray lip with center dip
                moveTo(3.1f, 14.6f)
                lineTo(8.5f, 14.6f)
                quadTo(9.4f, 17.1f, 12f, 17.1f)
                quadTo(14.6f, 17.1f, 15.5f, 14.6f)
                lineTo(20.9f, 14.6f)
            }
        }
    }

    // SF "doc.text"
    val DocText: ImageVector by lazy {
        icon("MacDocText") {
            strokePath(lineWidth = 1.8f) {
                moveTo(5.2f, 4.6f)
                quadTo(5.2f, 3.0f, 6.8f, 3.0f)
                lineTo(13.6f, 3.0f)
                lineTo(18.8f, 8.2f)
                lineTo(18.8f, 19.4f)
                quadTo(18.8f, 21.0f, 17.2f, 21.0f)
                lineTo(6.8f, 21.0f)
                quadTo(5.2f, 21.0f, 5.2f, 19.4f)
                close()
                moveTo(13.6f, 3.2f)
                lineTo(13.6f, 7.4f)
                quadTo(13.6f, 8.2f, 14.4f, 8.2f)
                lineTo(18.6f, 8.2f)
                // Text lines
                moveTo(8.6f, 11.4f); lineTo(15.4f, 11.4f)
                moveTo(8.6f, 14.4f); lineTo(15.4f, 14.4f)
                moveTo(8.6f, 17.4f); lineTo(13.0f, 17.4f)
            }
        }
    }

    // SF "doc.fill"
    val DocFill: ImageVector by lazy {
        icon("MacDocFill") {
            fillPath {
                // Main page body leaving subtle space for folded dog-ear corner
                moveTo(6.6f, 2.8f)
                lineTo(13.0f, 2.8f)
                lineTo(13.0f, 7.6f)
                quadTo(13.0f, 8.8f, 14.2f, 8.8f)
                lineTo(19.0f, 8.8f)
                lineTo(19.0f, 19.4f)
                quadTo(19.0f, 21.2f, 17.2f, 21.2f)
                lineTo(6.6f, 21.2f)
                quadTo(4.8f, 21.2f, 4.8f, 19.4f)
                lineTo(4.8f, 4.6f)
                quadTo(4.8f, 2.8f, 6.6f, 2.8f)
                close()
                // Folded dog-ear flap
                moveTo(14.3f, 3.0f)
                lineTo(18.8f, 7.5f)
                lineTo(14.7f, 7.5f)
                quadTo(14.3f, 7.5f, 14.3f, 7.1f)
                close()
            }
        }
    }

    // SF "folder.fill"
    val FolderFill: ImageVector by lazy {
        icon("MacFolderFill") {
            fillPath {
                moveTo(2.4f, 6.2f)
                quadTo(2.4f, 4.3f, 4.3f, 4.3f)
                lineTo(8.7f, 4.3f)
                quadTo(9.7f, 4.3f, 10.4f, 5.1f)
                lineTo(11.6f, 6.5f)
                lineTo(19.7f, 6.5f)
                quadTo(21.6f, 6.5f, 21.6f, 8.4f)
                lineTo(21.6f, 17.8f)
                quadTo(21.6f, 19.7f, 19.7f, 19.7f)
                lineTo(4.3f, 19.7f)
                quadTo(2.4f, 19.7f, 2.4f, 17.8f)
                close()
            }
        }
    }

    // SF "doc.on.clipboard"
    val DocOnClipboard: ImageVector by lazy {
        icon("MacDocOnClipboard") {
            strokePath(lineWidth = 1.7f) {
                // Back clipboard top clip
                roundedRect(6.8f, 2.5f, 11.8f, 4.9f, 0.8f)
                // Back clipboard outline
                moveTo(8.5f, 18.6f)
                lineTo(5.6f, 18.6f)
                quadTo(4.2f, 18.6f, 4.2f, 17.2f)
                lineTo(4.2f, 5.0f)
                quadTo(4.2f, 3.7f, 5.6f, 3.7f)
                lineTo(6.8f, 3.7f)
                moveTo(11.8f, 3.7f)
                lineTo(13.0f, 3.7f)
                quadTo(14.4f, 3.7f, 14.4f, 5.0f)
                lineTo(14.4f, 7.6f)
                // Front document sheet
                moveTo(9.8f, 9.2f)
                quadTo(9.8f, 7.8f, 11.2f, 7.8f)
                lineTo(15.6f, 7.8f)
                lineTo(19.6f, 11.8f)
                lineTo(19.6f, 19.8f)
                quadTo(19.6f, 21.2f, 18.2f, 21.2f)
                lineTo(11.2f, 21.2f)
                quadTo(9.8f, 21.2f, 9.8f, 19.8f)
                close()
                moveTo(15.6f, 8.0f)
                lineTo(15.6f, 11.0f)
                quadTo(15.6f, 11.8f, 16.4f, 11.8f)
                lineTo(19.4f, 11.8f)
            }
        }
    }

    // SF "arrow.down.circle.fill"
    val ArrowDownCircleFill: ImageVector by lazy {
        icon("MacArrowDownCircleFill") {
            fillPath(fillType = PathFillType.EvenOdd) {
                circle(12f, 12f, 10f)
                // Crisp inner down arrow cutout
                moveTo(10.95f, 7.4f)
                lineTo(13.05f, 7.4f)
                lineTo(13.05f, 13.2f)
                lineTo(15.5f, 10.75f)
                lineTo(16.95f, 12.2f)
                lineTo(12f, 17.15f)
                lineTo(7.05f, 12.2f)
                lineTo(8.5f, 10.75f)
                lineTo(10.95f, 13.2f)
                close()
            }
        }
    }

    // SF "arrow.up.circle.fill"
    val ArrowUpCircleFill: ImageVector by lazy {
        icon("MacArrowUpCircleFill") {
            fillPath(fillType = PathFillType.EvenOdd) {
                circle(12f, 12f, 10f)
                // Crisp inner up arrow cutout
                moveTo(10.95f, 16.6f)
                lineTo(13.05f, 16.6f)
                lineTo(13.05f, 10.8f)
                lineTo(15.5f, 13.25f)
                lineTo(16.95f, 11.8f)
                lineTo(12f, 6.85f)
                lineTo(7.05f, 11.8f)
                lineTo(8.5f, 13.25f)
                lineTo(10.95f, 10.8f)
                close()
            }
        }
    }

    // SF "checkmark.circle.fill"
    val CheckmarkCircleFill: ImageVector by lazy {
        icon("MacCheckmarkCircleFill") {
            fillPath(fillType = PathFillType.EvenOdd) {
                circle(12f, 12f, 10f)
                // Crisp inner checkmark cutout
                moveTo(7.2f, 12.3f)
                lineTo(8.6f, 10.9f)
                lineTo(10.4f, 12.7f)
                lineTo(15.4f, 7.7f)
                lineTo(16.8f, 9.1f)
                lineTo(10.4f, 15.5f)
                close()
            }
        }
    }

    // SF "exclamationmark.triangle.fill"
    val ExclamationTriangleFill: ImageVector by lazy {
        icon("MacExclamationTriangleFill") {
            fillPath(fillType = PathFillType.EvenOdd) {
                moveTo(10.4f, 4.3f)
                quadTo(12f, 1.8f, 13.6f, 4.3f)
                lineTo(21.4f, 17.6f)
                quadTo(22.8f, 20.1f, 19.9f, 20.1f)
                lineTo(4.1f, 20.1f)
                quadTo(1.2f, 20.1f, 2.6f, 17.6f)
                close()
                // Inner '!' cutout
                roundedRect(11.0f, 8.6f, 13.0f, 14.3f, 1.0f)
                circle(12f, 16.9f, 1.15f)
            }
        }
    }

    // SF "questionmark.circle.fill"
    val QuestionmarkCircleFill: ImageVector by lazy {
        icon("MacQuestionmarkCircleFill") {
            fillPath(fillType = PathFillType.EvenOdd) {
                circle(12f, 12f, 10f)
                // Crisp inner '?' hook cutout + dot cutout
                moveTo(8.6f, 9.4f)
                curveTo(8.6f, 7.4f, 10.1f, 6.2f, 12.1f, 6.2f)
                curveTo(14.1f, 6.2f, 15.5f, 7.4f, 15.5f, 9.2f)
                curveTo(15.5f, 10.8f, 14.3f, 11.4f, 13.4f, 12.1f)
                curveTo(12.9f, 12.5f, 12.8f, 12.9f, 12.8f, 14.0f)
                lineTo(11.1f, 14.0f)
                curveTo(11.1f, 12.4f, 11.4f, 11.7f, 12.3f, 11.0f)
                curveTo(13.1f, 10.4f, 13.7f, 10.0f, 13.7f, 9.2f)
                curveTo(13.7f, 8.3f, 13.0f, 7.7f, 12.0f, 7.7f)
                curveTo(11.0f, 7.7f, 10.4f, 8.3f, 10.3f, 9.4f)
                close()
                circle(12f, 16.9f, 1.15f)
            }
        }
    }

    // SF "gearshape"
    val Gear: ImageVector by lazy {
        icon("MacGear") {
            strokePath(lineWidth = 1.8f) {
                circle(12f, 12f, 3.1f)
                moveTo(19.4f, 15.0f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 19.73f, 16.82f)
                lineTo(19.79f, 16.88f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 16.96f, 19.71f)
                lineTo(16.9f, 19.65f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 15.08f, 19.32f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 14.08f, 20.83f)
                lineTo(14.08f, 21.0f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 10.08f, 21.0f)
                lineTo(10.08f, 20.91f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 9.0f, 19.4f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 7.18f, 19.73f)
                lineTo(7.12f, 19.79f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 4.29f, 16.96f)
                lineTo(4.35f, 16.9f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 4.68f, 15.08f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 3.17f, 14.08f)
                lineTo(3.0f, 14.08f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 3.0f, 10.08f)
                lineTo(3.09f, 10.08f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 4.6f, 9.0f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 4.27f, 7.18f)
                lineTo(4.21f, 7.12f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 7.04f, 4.29f)
                lineTo(7.1f, 4.35f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 8.92f, 4.68f)
                lineTo(9.0f, 4.68f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 10.0f, 3.17f)
                lineTo(10.0f, 3.0f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 14.0f, 3.0f)
                lineTo(14.0f, 3.09f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 15.0f, 4.6f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 16.82f, 4.27f)
                lineTo(16.88f, 4.21f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 19.71f, 7.04f)
                lineTo(19.65f, 7.1f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 19.32f, 8.92f)
                lineTo(19.32f, 9.0f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 20.83f, 10.0f)
                lineTo(21.0f, 10.0f)
                arcTo(2.0f, 2.0f, 0f, isMoreThanHalf = false, isPositiveArc = true, 21.0f, 14.0f)
                lineTo(20.91f, 14.0f)
                arcTo(1.65f, 1.65f, 0f, isMoreThanHalf = false, isPositiveArc = false, 19.4f, 15.0f)
                close()
            }
        }
    }

    // SF "arrow.down.circle"
    val ArrowDownCircle: ImageVector by lazy {
        icon("MacArrowDownCircle") {
            strokePath(lineWidth = 1.9f) {
                circle(12f, 12f, 9f)
                moveTo(12f, 7.8f)
                lineTo(12f, 15.6f)
                moveTo(8.8f, 12.6f)
                lineTo(12f, 16.0f)
                lineTo(15.2f, 12.6f)
            }
        }
    }
}
