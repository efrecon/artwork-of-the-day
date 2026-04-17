# One ArtWork a Day

Downloads one artwork per day from the [AIC] collection.
These images can be fed into the [image URL plugin for the InkyPi][imgurl].
Downloaded images [will][workflow]:

- be in landscape mode.
- be annotated with the title, painter and date.
- have the exact resolution of 1920x1080
- maximized, respecting the original ratio inside the 1920x1080 canvas.
  White background.

I use these images to show one painting a day to my mother.
She used to paint as a hobby and is now 95 years old.

Today's Oil Painting
![oil-painting](https://efrecon.github.io/artwork-of-the-day/oil-painting.jpg)

Today's Landscape
![landscape](https://efrecon.github.io/artwork-of-the-day/landscape.jpg)

  [workflow]: ./.github/workflows/generate.yml
  [AIC]: https://api.artic.edu/docs/#introduction
  [imgurl]: https://github.com/fatihak/InkyPi/tree/main/src/plugins/image_url

## `aic.sh`

[`aic.sh`][aicsh] is the script behind these pictures.
The script is inspired from [aic-bash] but has diverged a bit.
Most important of all,
`aic.sh` will properly set the `AIC-User-Agent` [header] when performing IIIF calls.
This properly bypasses Cloudflare's user validation.

The script can be controlled both through environment variables, led by `AIC_`,
or through CLI options.
The script takes the path to a (JPG) image as an argument.
When no image is provided, its content will be streamed.
CLI options focus on the most important features and are as follows:

- `-b`: Blank, no engraved annotation on the target image.
- `-r`: Target resolution of the downloaded image.
  Defaults to `1920x1080`.
  Calls to the IIIF API will maximize the width or heigth depending on the ratio of the original image.
  When the seed is empty, the script will use the resolution to only download landscape or portrait images.
- `-q`: Path to the JSON query to perform.
  In that file, the string `%SEED%` will be replaced with the value of the seed.
- `-s`: Random seed to use.
  Default is blank, then the script will loop until a landscape or portrait image could be downloaded.
- `-B`: Value of the background when centering the downloaded image onto the target image at the specified resolution.
  Set to empty to not add a background, nor center,
  then the target image will either have the target width or the target height.
- `-v`: Increase verbosity each time it it repeated.
- `-h`: Shows inline help and recognized environment variables, and exit.

  [aicsh]: ./aic.sh
  [aic-bash]: https://github.com/art-institute-of-chicago/aic-bash
  [header]: https://api.artic.edu/docs/#authentication
