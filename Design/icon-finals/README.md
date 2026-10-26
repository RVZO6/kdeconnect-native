# Final icon takes

Icon Composer documents for the app icon. Every layer is clipped to the
macOS tile outline, so arcs that leave the tile keep the rounded corners.

- **final-a:** the layout of variant 13 (gap above the phone, large outer arc out of the tile) with the fade of variant 12.
- **final-b:** as a, with a stronger fade.
- **final-c:** as a, with a larger gap above the phone.
- **final-d:** two arcs, thinner and higher than variant 11, with even spacing.
- **final-e:** as d, thinner still and a little higher.
- **final-f:** a complete two-arc Wi-Fi mark with a dot, floating above the phone.
- **final-a2:** final-a with a stronger fade (arcs keep their 62/52/42 width; opacity 100/65/36%) and a soft top-to-bottom background gradient from #41B2F7 to #1E82E6. This is the app icon now (`Resources/AppIcon.icon`).

To use another take, replace `Resources/AppIcon.icon` with its `.icon` folder and run `Scripts/build-app.sh`.
