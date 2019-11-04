module Image.Internal.BMP exposing (decode, encode)

import Bitwise exposing (and)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D exposing (Decoder, Step(..))
import Bytes.Encode as E exposing (Encoder, unsignedInt16, unsignedInt32, unsignedInt8)
import Image.Internal.Decode as D exposing (andMap)
import Image.Internal.Encode exposing (unsignedInt24)
import Image.Internal.ImageData as ImageData exposing (Image(..), Order(..), PixelFormat(..), defaultOptions)


decode : Bytes -> Maybe { width : Int, height : Int, data : Image }
decode bytes =
    let
        decoder =
            D.string 2
                |> D.andThen
                    (\bm ->
                        if bm == "BM" then
                            decodeInfo
                                |> D.andThen
                                    (\info ->
                                        let
                                            decoder_ =
                                                case info.bitsPerPixel of
                                                    32 ->
                                                        Just (decode32 info)

                                                    24 ->
                                                        Just (decode24 info)

                                                    16 ->
                                                        Just (decode16 info)

                                                    _ ->
                                                        Nothing
                                        in
                                        case decoder_ of
                                            Just ddd ->
                                                D.succeed
                                                    { width = info.width
                                                    , height = info.height
                                                    , data = Bytes defaultOptions ddd bytes
                                                    }

                                            _ ->
                                                D.fail
                                    )

                        else
                            D.fail
                    )

        decodeInfo =
            D.succeed
                (\fileSize _ pixelStart dibHeader width height color_planes bitsPerPixel compression dataSize ->
                    { fileSize = fileSize
                    , pixelStart = pixelStart
                    , dibHeader = dibHeader
                    , width = width
                    , height = height
                    , color_planes = color_planes
                    , bitsPerPixel = bitsPerPixel
                    , compression = compression
                    , dataSize = dataSize
                    }
                )
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt16 LE)
                |> andMap (D.unsignedInt16 LE)
                |> andMap (D.unsignedInt32 LE)
                |> andMap (D.unsignedInt32 LE)
    in
    D.decode decoder bytes


encode : Image -> Bytes
encode imageData =
    let
        { format, defaultColor, order } =
            ImageData.options imageData

        bytesPerPixel =
            bytesPerPixel_ format

        padWidth w =
            let
                improveMe =
                    and (4 - and (w * bytesPerPixel) bytesPerPixel) bytesPerPixel
            in
            if improveMe == 4 then
                0

            else
                improveMe

        width =
            ImageData.width_ imageData

        data =
            ImageData.toList2d imageData

        orderRight =
            order == RightDown || order == RightUp

        orderUp =
            order == RightUp || order == LeftUp

        encodeFolder remaining height totalBytes acc =
            case remaining of
                row :: rest ->
                    let
                        ( pxCount_, encodedRow_ ) =
                            encodeRow (intToBytes bytesPerPixel) row 0 []

                        -- if this row has fewer pixels than the width, recalculate
                        ( rowWidth, encodedRow ) =
                            let
                                padding =
                                    width - pxCount_
                            in
                            if padding > 0 then
                                encodeRow
                                    (intToBytes bytesPerPixel)
                                    (List.repeat padding defaultColor)
                                    pxCount_
                                    encodedRow_

                            else
                                ( pxCount_, encodedRow_ )

                        extra =
                            padWidth rowWidth

                        paddingEncoders =
                            List.repeat extra (E.unsignedInt8 0)

                        withRow =
                            if orderRight then
                                if extra == 0 then
                                    E.sequence (List.reverse encodedRow) :: acc

                                else
                                    E.sequence (List.reverse encodedRow ++ paddingEncoders) :: acc

                            else if extra == 0 then
                                E.sequence encodedRow :: acc

                            else
                                E.sequence (encodedRow ++ paddingEncoders) :: acc
                    in
                    encodeFolder rest (height + 1) (totalBytes + rowWidth * bytesPerPixel + extra) withRow

                [] ->
                    let
                        body =
                            if orderUp then
                                List.reverse acc

                            else
                                acc
                    in
                    if format == RGBA then
                        header32 width height totalBytes body

                    else
                        header16_24 (8 * bytesPerPixel) width height totalBytes body
    in
    encodeFolder data 0 0 []
        |> E.sequence
        |> E.encode


encodeRow : (a -> b) -> List a -> Int -> List b -> ( Int, List b )
encodeRow f items i acc =
    case items of
        px :: rest ->
            let
                newI =
                    i + 1

                newAcc =
                    f px :: acc
            in
            encodeRow f rest newI newAcc

        _ ->
            ( i, acc )


bytesPerPixel_ : PixelFormat -> number
bytesPerPixel_ format =
    case format of
        RGBA ->
            4

        RGB ->
            3

        LUMINANCE_ALPHA ->
            2

        ALPHA ->
            1


bitsPerPixel_ : PixelFormat -> number
bitsPerPixel_ =
    bytesPerPixel_ >> (*) 8


intToBytes bpp color =
    case bpp of
        1 ->
            unsignedInt8 color

        2 ->
            unsignedInt16 Bytes.LE color

        3 ->
            unsignedInt24 Bytes.LE color

        4 ->
            unsignedInt32 Bytes.LE color

        _ ->
            unsignedInt8 0


header2_4_8 =
    --    To define colors used by the bitmap image data (Pixel array)      Mandatory for color depths ≤ 8 bits
    []


header16_24 : Int -> Int -> Int -> Int -> List Encoder -> List Encoder
header16_24 bitsPerPixel w h dataSize accum =
    {- BMP Header -}
    -- "BM" -|- ID field ( 42h, 4Dh )
    --   [ 0x42, 0x4D ] |> List.map unsignedInt8
    unsignedInt16 BE 0x424D
        --   70 bytes (54+16) -|- Size of the BMP file
        -- , [ 0x46, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE (54 + dataSize)
        -- -- Unused -|- Application specific
        -- , [ 0x00, 0x00 ] |> List.map
        -- -- Unused -|- Application specific
        -- , [ 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 0
        -- 54 bytes (14+40) -|- Offset where the pixel array (bitmap data) can be found
        -- , [ 0x36, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE (14 + 40)
        {- DIB Header -}
        --40 bytes -|- Number of bytes in the DIB header (from this point)
        -- , [ 0x28, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 40
        -- 2 pixels (left to right order) -|- Width of the bitmap in pixels
        -- , [ 0x02, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE w
        -- 2 pixels (bottom to top order) -|- Height of the bitmap in pixels. Positive for bottom to top pixel order.
        -- , [ 0x02, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE h
        --1 plane -|-  Number of color planes being used
        -- , [ 0x01, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt16 LE 1
        -- 24 bits -|- Number of bits per pixel
        -- , [ 0x18, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt16 LE bitsPerPixel
        -- 0 -|- BI_RGB, no pixel array compression used
        -- , [ 0x00, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 0
        -- 16 bytes -|- Size of the raw bitmap data (including padding)
        -- , [ 0x10, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE dataSize
        -- 2835 pixels/metre horizontal  | Print resolution of the image, 72 DPI × 39.3701 inches per metre yields 2834.6472
        -- , [ 0x13, 0x0B, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 2835
        -- 2835 pixels/metre vertical
        -- , [ 0x13, 0x0B, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 2835
        -- 0 colors -|- Number of colors in the palette
        -- , [ 0x00, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 0
        -- 0 important colors -|- 0 means all colors are important
        -- , [ 0x00, 0x00, 0x00, 0x00 ] |> List.map unsignedInt8
        :: unsignedInt32 LE 0
        :: accum


header32 : Int -> Int -> Int -> List Encoder -> List Encoder
header32 w h dataSize accum =
    {- BMP Header -}
    unsignedInt16 BE 0x424D
        -- "BM"    ID field (42h, 4Dh)
        :: unsignedInt32 LE (122 + dataSize)
        --  Size of the BMP file
        :: unsignedInt32 LE 0
        --Unused - Application specific
        :: unsignedInt32 LE 122
        --122 bytes (14+108) Offset where the pixel array (bitmap data) can be found
        {- DIB Header -}
        :: unsignedInt32 LE 108
        -- 108 bytes    Number of bytes in the DIB header (from this point)
        :: unsignedInt32 LE w
        -- Width of the bitmap in pixels
        :: unsignedInt32 LE h
        -- Height of the bitmap in pixels
        :: unsignedInt16 LE 1
        --  Number of color planes being used
        :: unsignedInt16 LE 32
        -- Number of bits per pixel
        :: unsignedInt32 LE 3
        -- BI_BITFIELDS:: no pixel array compression used
        :: unsignedInt32 LE dataSize
        -- Size of the raw bitmap data (including padding)
        :: unsignedInt32 LE 2835
        -- 2835 pixels/metre horizontal
        :: unsignedInt32 LE 2835
        -- 2835 pixels/metre vertical
        :: unsignedInt32 LE 0
        -- Number of colors in the palette
        :: unsignedInt32 LE 0
        --important colors (0 means all colors are important)
        :: unsignedInt32 LE 0xFF000000
        --00FF0000 in big-endian Red channel bit mask (valid because BI_BITFIELDS is specified)
        :: unsignedInt32 LE 0x00FF0000
        --0000FF00 in big-endian    Green channel bit mask (valid because BI_BITFIELDS is specified)
        :: unsignedInt32 LE 0xFF00
        --000000FF in big-endian    Blue channel bit mask (valid because BI_BITFIELDS is specified)
        :: unsignedInt32 LE 0xFF
        --FF000000 in big-endian    Alpha channel bit mask
        :: unsignedInt32 LE 0x206E6957
        --   little-endian "Win "    LCS_WINDOWS_COLOR_SPACE
        --CIEXYZTRIPLE Color Space endpoints    Unused for LCS "Win " or "sRGB"
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        :: unsignedInt32 LE 0
        -----------
        :: unsignedInt32 LE 0
        --0 Red Gamma    Unused for LCS "Win " or "sRGB"
        :: unsignedInt32 LE 0
        --0 Green Gamma    Unused for LCS "Win " or "sRGB"
        :: unsignedInt32 LE 0
        --0 Blue Gamma    Unused for LCS "Win " or "sRGB"
        :: accum


decode32 : { a | pixelStart : Int, dataSize : Int, width : Int } -> Decoder Image
decode32 info =
    D.bytes info.pixelStart
        |> D.andThen (\_ -> D.listR (info.dataSize // 4) (D.unsignedInt32 LE))
        |> D.map (List defaultOptions info.width)


decode24 : { a | pixelStart : Int, height : Int, width : Int } -> Decoder Image
decode24 info =
    D.bytes info.pixelStart
        |> D.andThen (\_ -> D.listR info.height (D.listR info.width (D.unsignedInt24 LE)))
        |> D.map (List.concat >> List defaultOptions info.width)


decode16 : { a | pixelStart : Int, height : Int, width : Int } -> Decoder Image
decode16 info =
    D.bytes info.pixelStart
        |> D.andThen (\_ -> D.listR info.height (D.listR info.width (D.unsignedInt16 LE)))
        |> D.map (List.concat >> List defaultOptions info.width)