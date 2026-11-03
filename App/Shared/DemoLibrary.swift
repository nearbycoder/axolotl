#if DEBUG
import Foundation
import AxolotlKit

/// Sample library used for screenshots. Debug builds only.
extension AppModel {
    func loadDemoLibrary() {
        for note in liveNotes { replica.deleteForever(note.id) }
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let notes: [(String, Date, Bool)] = [
            ("""
            # Atlas Q3 Roadmap

            The goal this quarter is to make **onboarding feel effortless** and cut time-to-first-note in half.

            ## Priorities
            - [x] Ship the redesigned welcome flow
            - [x] Instrument the first-run funnel
            - [ ] Sync status that explains itself
            - [ ] Offline-first attachments

            > [!NOTE]
            > Design review moved to Thursday. Notes are in [[Design Review]].

            ## Open questions
            - Do we keep the ==three-column layout== on smaller iPads?
            - Pricing for teams, see #work/atlas/pricing

            #work/atlas
            """, ago(0.4), true),
            ("""
            # Design Review

            Attendees: Maya, Theo, Priya

            - Typography feels *much* calmer with the new line height
            - Tag pills should stay subtle in dark themes
            - Checkbox hit targets are too small on iPhone

            > Simplicity is about subtracting the obvious and adding the meaningful.

            Follow-ups tracked in [[Atlas Q3 Roadmap]].

            #work/atlas
            """, ago(3), false),
            ("""
            # Lisbon in October

            ## Itinerary
            - [x] Book flights
            - [x] Apartment in Alfama
            - [ ] Tram 28 early, before the crowds
            - [ ] Day trip to Sintra
            - [ ] Pastéis de nata at Manteigaria

            ## Places
            | Neighborhood | Why |
            | --- | --- |
            | Alfama | Fado and views |
            | Príncipe Real | Gardens and shops |

            #travel/portugal
            """, ago(20), false),
            ("""
            # Weeknight Miso Ramen

            Serves 2 · 25 minutes

            ## Ingredients
            - 2 tbsp white miso
            - 1 tbsp tahini
            - 4 cups chicken stock
            - Fresh noodles, soft eggs, scallions

            ## Method
            1. Whisk miso and tahini into warm stock.
            2. Cook noodles; ==don't overcook==.
            3. Top with eggs, scallions and chili oil.

            #recipes
            """, ago(30), false),
            ("""
            # Deep Work — Cal Newport

            > Clarity about what matters provides clarity about what does not.

            ## Takeaways
            - Schedule **deep blocks** before the day fills up
            - Shutdown ritual: review tomorrow, then stop
            - Boredom is a skill worth practicing

            #books
            """, ago(52), false),
            ("""
            # Sync engine notes

            Each field carries a hybrid logical clock; bodies merge with their lineage.

            ```swift
            let merged = TextMerge.merge(
                base: base, ours: local, theirs: remote,
                oursIsPrimary: local.rev > remote.rev)
            ```

            - [ ] Benchmark merges on 50k-word notes
            - [x] Fuzz three-device convergence

            #dev
            """, ago(75), false),
            ("""
            # Morning pages

            Woke up early and walked to the river before anyone else was out. The light on the water was the kind of quiet I want more of this year.

            Things I'm grateful for: slow coffee, a good book, and a clear inbox.

            #journal
            """, ago(98), false),
        ]
        for (body, date, pinned) in notes {
            let id = replica.createNote(body: body, created: date.addingTimeInterval(-86400 * 3))
            replica.setCreated(id, date.addingTimeInterval(-86400 * 3))
            if pinned { replica.setPinned(id, true) }
            // Stamp the modified time after creation so list ordering is realistic.
            replica.updateBody(id, body + "\n", date: date)
            replica.updateBody(id, body, date: date)
        }
        let icons = ["work": "briefcase", "travel": "airplane", "recipes": "fork.knife", "books": "book", "journal": "sun.max", "dev": "chevron.left.forwardslash.chevron.right"]
        for (tag, icon) in icons { replica.setTagIcon(tag, icon) }
        replica.setTagPinned("work", true)
        UserDefaults.standard.removeObject(forKey: "lastNoteId")
    }
}
#endif
