# Credits

## xkcd comics

By Randall Munroe, licensed [Creative Commons Attribution-NonCommercial 2.5](https://xkcd.com/license.html). The app loads them straight from xkcd.com and is free and non-commercial.

## Font

`XKCDReader/Resources/Fonts/xkcd.otf` (and the copy in `XKCDWidgets/`) is from [ipython/xkcd-font](https://github.com/ipython/xkcd-font), licensed [Creative Commons Attribution-NonCommercial 3.0](https://github.com/ipython/xkcd-font/blob/master/LICENSE).

## The original app

Mike Amaral's [xkcd: Open Source](https://github.com/mamaral/xkcd-Open-Source) (MIT, Copyright (c) 2015 Michael Amaral). This app rebuilds its mosaic grid from scratch and uses none of its code.

The Classic app icon (`scripts/classic-icon.png`) is the original app's icon, used under its MIT license. The two characters in it are Randall Munroe's, under the same CC BY-NC 2.5 license as the comics. The other icons were drawn for this app.

## Explanations

Written by the contributors to [explain xkcd](https://www.explainxkcd.com) and fetched from its wiki when the reader asks for one. The wiki is licensed [Creative Commons Attribution-ShareAlike 3.0](https://creativecommons.org/licenses/by-sa/3.0/) (see [its copyright page](https://www.explainxkcd.com/wiki/index.php/explain_xkcd:Copyrights)). The app shows the "Explanation" section of the comic's page with the source, authors, license, a link to the full page, and a note that it's reformatted with tables and pictures left out. The text is only kept in memory while the app runs.

## Enlarging model

`XKCDReader/Resources/XkcdUpscaler.mlpackage` and `XkcdUpscalerTile.mlpackage` were trained for this app on xkcd's own images only, in the separate `xkcd-upscaler` project.
