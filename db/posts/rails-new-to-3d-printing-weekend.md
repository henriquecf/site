I was putting together an Hour of Code session for a local school. Kids ages 6 to 10, years 1 through 4, and I wanted something better than a generic tutorial on a third-party platform. I wanted them to actually make something. The plan: an app where they design name tags that get 3D-printed on my Bambu Lab P2S, play a block-based coding game, and debug pre-written programs. Three activities, all in Portuguese, deployed and ready for a classroom.

I had a weekend. Every commit was co-authored with Claude Code.

## What I needed

Three standalone activities, each accessible from a landing page tied to a classroom session:

**Tag designer.** Kids type their name, pick an icon from a grid of options (star, rocket, crown, paw print, anchor, and more), and adjust the text size with a slider. A live SVG preview updates as they type. After submitting, the admin downloads their designs as 3MF files and prints them on the Bambu Lab P2S. Two-color prints: gray base plate with yellow raised text and icon.

**Coding game.** A 6x6 grid maze. Kids add directional commands (up, down, left, right) to build a program, then run it and watch their character navigate the maze step by step. Five themes (space, animals, pirates, ocean, forest), each with its own emoji characters, obstacle, and color palette. Repeat blocks for introducing loops. Four levels per school year, progressively harder.

**Bug hunt.** Same maze grid and themes, but instead of writing a program from scratch, kids see a pre-loaded program with intentional bugs. They click a command to select it, use arrow keys to replace it, and run to see if the fix worked. Step-by-step execution highlights each block as it runs. For years 3-4 only, since reading existing code requires more cognitive load.

The whole thing tied together by a session model: the teacher creates a session for a specific school year, and the app adjusts its content accordingly.

The stack: Rails 8.1, SQLite, Stimulus, no Node.js, no external JavaScript. Single CSS file. Deployed via Kamal.

## Sunday evening: the scaffold

The first commit landed at 7:24 PM. I described the two initial activities to Claude Code (the bug hunt came later), laid out the user flows, the game mechanics, and what the UI should feel like. Claude generated models, controllers, views, Stimulus controllers, and all the CSS.

The tag designer got a Stimulus controller for live SVG preview as the kid types, a form with a visual icon picker, and a gallery view showing all submitted designs. The coding game got something more ambitious: a Stimulus controller that manages program building, keyboard shortcuts, animated step-by-step execution, collision detection, and confetti on completion.

```javascript
export default class extends Controller {
  static targets = ["grid", "program", "message", "runBtn",
                     "levelBtn", "levelBar", "repeatBtn", "celebration"]
  static values = {
    theme: String,
    character: String,
    goal: String,
    obstacle: String,
    pathColor: String,
    groundColor: String,
    levels: Object
  }

  connect() {
    this.currentLevel = 1
    this.program = [] // Array of { type, children?, count? }
    this.completedLevels = new Set()
    this.isRunning = false
    this.inRepeatMode = false
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
    this.loadLevel(1)
  }
```

The `levels` value is a JSON object passed from the server via a data attribute. The server decides which level set to show based on the session's school year, and the Stimulus controller picks it up on connect. Server-rendered shell, client-side game logic. Hotwire as intended.

Programs are stored as arrays of command objects. Repeat blocks contain a `children` array, so the program is actually a tree. When you hit run, the controller flattens the tree (expanding repeat blocks), then executes each step with a 350ms delay between moves. If the character hits a wall, the grid shakes and the obstacle cell flashes. If it reaches the goal, confetti rains down.

All of that was in the first commit. A substantial amount of code generated from a description of what I wanted the app to do.

## Sunday night: 3D printing from a web app

Four hours later, the second commit. This was the part I wasn't sure would work.

I needed the admin panel to download tag designs as 3MF files that I could open directly in Bambu Studio, slice, and print. 3MF is a 3D printing format: a ZIP file containing XML with mesh data defined as vertices and triangles. I described what I needed: a base plate with a hole for a keychain ring, raised text showing the kid's name, a raised icon, two separate meshes for dual-extruder color printing, and the ability to batch multiple tags onto a single 256mm build plate.

Claude produced a service layer with five classes, no external dependencies beyond `rubyzip`:

```ruby
module ThreeMf
  class Generator
    TAG_WIDTH = 60.0       # mm
    TAG_HEIGHT = 34.0      # mm
    BASE_THICKNESS = 2.0   # mm
    RAISED_HEIGHT = 0.8    # mm above base
    HOLE_RADIUS = 2.5      # mm

    def self.generate_single(tag_design)
      base_mesh, overlay_mesh = build_tag_meshes(tag_design)

      writer = Writer.new
      writer.add_tag(base_mesh, overlay_mesh, name: tag_design.student_name)
      writer.to_zip_buffer
    end
  end
end
```

Under that clean interface: a pixel font with hardcoded 5x7 bitmap glyphs for every letter, number, and punctuation mark:

```ruby
CHARS = {
  "A" => %w[01110 10001 10001 11111 10001 10001 10001],
  "B" => %w[11110 10001 10001 11110 10001 10001 11110],
  "C" => %w[01110 10001 10000 10000 10000 10001 01110],
  # ... every character as a 5×7 bitmap
}
```

An SVG icon rasterizer that parses path commands (including cubic and quadratic bezier curves), flattens them via recursive subdivision, and samples to a 14x14 pixel grid using point-in-shape detection. A mesh generator that turns each filled pixel into a 3D box:

```ruby
def add_box(x, y, z, w, h, d)
  b = @vertices.length
  # 8 vertices of the box
  add_vertex(x,     y,     z)
  add_vertex(x + w, y,     z)
  add_vertex(x + w, y + h, z)
  add_vertex(x,     y + h, z)
  add_vertex(x,     y,     z + d)
  add_vertex(x + w, y,     z + d)
  add_vertex(x + w, y + h, z + d)
  add_vertex(x,     y + h, z + d)

  # 12 triangles (2 per face, outward normals)
  add_triangle(b, b + 2, b + 1)
  add_triangle(b, b + 3, b + 2)
  # ...
end
```

Each character in the kid's name becomes a column of tiny boxes on top of the base plate. Each filled pixel of their chosen icon becomes another box. The result is a blocky, pixel-art style 3D model that prints well and looks intentional.

The base plate uses a more involved algorithm: ray-rectangle intersection to generate the geometry around a circular keychain hole. The Writer class assembles the final ZIP with proper 3MF XML structure, content types, relationships, and Bambu Studio metadata for assigning filament colors to each mesh (extruder 1 for the gray base, extruder 2 for the yellow overlay).

The plate layout calculates grid positions to fit up to 18 tags in a 3x6 arrangement on the build plate, centered with margins. Download one file from the admin panel, send it to the printer.

I didn't specify the bezier flattening approach, the ray-casting for the hole geometry, the vertex coordinate rounding, or the Unicode normalization that strips accents from Portuguese names before rendering (José becomes JOSE for the pixel font). Those were Claude's calls. Some are textbook algorithms, some are pragmatic shortcuts. They produce valid 3MF files that Bambu Studio opens without complaint.

The third commit came 18 minutes later: game event tracking with fire-and-forget analytics, a session-aware home page, and an admin tag selector with checkboxes for choosing which tags to include in a plate download.

## Monday: polish and difficulty

Monday morning. Two things bothered me.

First, the app would be projected onto a classroom screen, and the layout didn't fit well at typical projector resolutions. I asked Claude to add responsive breakpoints and move the program blocks below the game board instead of beside it. The game needed to work at both desktop and projector aspect ratios.

Second, collision feedback. When a kid's character hits a wall, the program just stopped. No visual indication of *why*. I asked for feedback: grid shake on collision, the obstacle cell flashing red, the player emoji bouncing. Kids who can't read error messages need to *see* the failure. This was a one-line prompt that produced CSS animations and JavaScript state management across both the grid rendering and the execution loop.

Monday afternoon: difficulty scaling. One set of levels can't serve both 6-year-olds and 10-year-olds. Year 1 needs open grids with obvious 3-step paths. Year 4 needs tight mazes with dead ends and routes that require planning several moves ahead. The game mechanics stay identical, only the level geometry changes.

```ruby
LEVELS_BY_YEAR = {
  # Year 1: simplest — few moves, wide corridors
  1 => {
    1 => {
      grid: [
        [0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0],
        # ... open grid
      ],
      start: [0, 0],
      goal: [3, 0],
      hint: "Usa ➡️ para mover para a direita!"
    },
    # ...
  },
  # Year 4: hardest — tight corridors, dead ends
  4 => { # ... }
}
```

The level data lives in the controller as a constant. No database, no YAML file. It ships with the code. If a maze needs tweaking, I change the array and deploy.

## Monday evening: a third activity

I hadn't planned three activities. The tag designer and coding game seemed sufficient. But thinking about the older kids in years 3 and 4, I realized they'd blow through four maze levels and have nothing to do. I needed something that exercises a different skill.

Debugging. They'd see a buggy program, identify which commands are wrong, and fix them. Same visual language as the coding game (the maze grid, the themes, the step-by-step execution), but a fundamentally different cognitive challenge. Building a program from scratch is creative. Reading someone else's broken program and finding the errors is analytical.

The Bug Hunt reuses the maze grid and theme system. Pre-loaded programs have marked bug indices so kids know *how many* bugs to find, but not *which* commands are wrong. Click a command to select it, arrow keys to replace it. Run the program and watch it execute with per-block highlighting: green for steps that work, red for the step where it fails.

Because the coding game architecture was already solid, adding a whole new activity was straightforward. Same execution loop pattern, same theme data, same grid rendering. Claude built a new Stimulus controller and views that followed the established conventions.

## Tuesday morning: BFS

The final commit. I looked at the year 3 and 4 mazes and decided they weren't hard enough. The corridors were too wide, the solutions too obvious for kids who'd already done two other activities. I asked Claude to redesign them with tighter paths, more dead ends, and counterintuitive routing that forces planning.

Making mazes harder introduces a real risk: accidentally making one unsolvable. If a kid gets stuck on an impossible level, they'll think *they* failed, not that the maze is broken. Claude added BFS verification that checks every level: does a path exist from start to goal? Is every open cell reachable from the start? Every maze in the final version is provably solvable.

## What was mine, what was Claude's

I want to be specific about this.

Everything related to *what* to build was mine. The three activities and how they connect. The physical constraints: 60x34mm tags sized for keychains, the 256mm build plate on my specific printer, gray and yellow filament for contrast. The UX decisions: collision feedback so kids see why they failed, difficulty that scales with school year, program blocks below the board for projector screens. The decision to add a third activity on Monday evening, and what skill it should teach.

Everything related to *how* was Claude's. All the code. The 3MF format internals. The computational geometry for mesh generation. The bitmap font data. The SVG icon rasterizer and its bezier curve handling. The CSS with animations. The game level layouts. The Stimulus controller architecture.

The steering happened between commits: "make the mazes harder," "add collision feedback," "move the program below the board." Short prompts that each produced a working, tested change.

## Seven commits

Seven commits, Sunday evening to Tuesday morning. A deployed platform with three interactive activities, pure Ruby 3D file generation, classroom session management, game analytics, difficulty that adapts to the age group, and responsive design for school projectors.

The stack: Rails 8.1, SQLite, Stimulus, a single CSS file, and `rubyzip`. No Node.js, no external JavaScript, no CAD library. The admin downloads a 3MF file, opens it in Bambu Studio, and hits print. Kids walk home with a name tag they designed in a browser, printed on a machine that read a file generated by a Rails app.
