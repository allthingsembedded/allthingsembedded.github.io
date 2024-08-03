---
title: "Data Structures: Ditto::static_ptr<Base, Derived, ...>"
date: 2022-01-02T17:02:33+02:00
author: Javier Alvarez
layout: post
tags:
  - Sum types
  - ADT
  - C++
  - Standard Library
  - Container
  - API
  - Object-oriented
---

One of the nice things about `C++` compared to `C` is its ability to define reusable types and data structures. They make code reuse easier and also help with reasoning if the abstraction is high-level enough.

Today we are going to talk about `static_ptr` from the library [Ditto](https://github.com/javier-varez/ditto). Dynamic allocation is often forbidden when developing embedded systems. This leads to allocating most things either in the stack or globally. A `static_ptr` allows the user to statically allocate an object of a derived class and access it as a base class pointer. The nice thing is that it allows to easily implement the `factory pattern` if only one instance of each child is required at a time.

The following is an example of how a `static_ptr` could be used in the context of an embedded system with a display and a fixed number of screens (Menu, Game, About) that can be shown at any time in the display. Since there is only one display, only one screen can be shown at a time. Since only one screen is shown at a time in a given display, we need not worry about allocating each screen individually. Instead only enough memory for the largest can be allocated. This is what `static_ptr` does. It takes care of the ugly memory allocation (dealing with size and alignment requirements of each of the types), makes sure that there is always a valid instance and that the object lifecycle is correctly implemented (construction and destruction). In addition, it makes sure that objects are used only through there base API, creating a common API for all screens.

```c++
#include "Ditto/assert.h"
#include "Ditto/static_ptr.h"

/*
 * Screen is an abstract base class that provides a common interface for all
 * actual screen implementations.
 */
class Screen {
 public:
  enum class Type { Menu, Game, About };

  /*
   * Virtual destructors are required since the derived class is accessed and
   * destructed throught a base pointer
   */
  virtual ~Screen() {}

  /*
   * Called after it has been invalidated due to some user action or event.
   * The screen will be updated with the new changed contents.
   */
  virtual void Draw(Surface*) = 0;

  /*
   * Performs the exit animation on the surface.
   */
  virtual void DoExit(Surface*) = 0;

  /*
   * Performs the entry animation on the surface.
   */
  virtual void DoEntry(Surface*) = 0;

  /*
   * Handles events and delives them to the appropriate widget. If the event is
   * handled returns true.
   */
  virtual bool HandleEvent(Event*) = 0;
};

/*
 * Each of the specific diplay implementations. They may have different members,
 * sizes and alignment requirements. As long as all of them implement the base
 * class they can be used together with `static_ptr`
 */

class SplashScreen: public Screen {
  /* Implementation details omitted for readability */
};

class MenuScreen: public Screen {
  /* Implementation details omitted for readability */
};

class GameScreen: public Screen {
  /* Implementation details omitted for readability */
};

class AboutScreen: public Screen {
  /* Implementation details omitted for readability */
};

/*
 * The AppDisplay class handles all display events and is responsible of
 * creating transitions between different screens.
 */

class AppDisplay {
 public:
  AppDisplay() {
    /*
     * On construction, the splash screen is shown. Whenever the system is done
     * booting a new transition to the main Screen happens with the `Transition`
     * method.
     */
    m_screen.make<SplashScreen>();
  }

  /*
   * Handles touch and display events. Forwards them to the active screen.
   * Returns true if the event is handled.
   */
  bool HandleEvent(Event* event);
  void Transition(Screen::Type screen_type);

 private:
  /* Here we store the active screen */
  static_ptr<Screen, SplashScreen, MenuScreen, GameScreen, AboutScreen> m_screen;
  /* This is the underlying HW display */
  HwDisplay m_display;

  void ConstructScreen(Screen::Type screen_type);
};

bool UserDisplay::HandleEvent(Event* event) {
  return m_screen->HandleEvent(event);
}

void UserDisplay::Transition(Screen::Type screen_type) {
  m_screen->DoExit(m_display.GetSurface());

  ConstructScreen(screen_type);

  m_screen->DoEntry(m_display.GetSurface());
}

void UserDisplay::ConstructScreen(Screen::Type screen_type) {
  switch (screen_type) {
    /* Splash screen cannot be constructed after boot, therefore it is ommited
       on the factory method */
    case Screen::Type::Menu:
      m_screen.make<MenuScreen>();
      break;
    case Screen::Type::Game:
      m_screen.make<GameScreen>();
      break;
    case Screen::Type::About:
      m_screen.make<AboutScreen>();
      break;
    default:
      DITTO_UNIMPLEMENTED();
  }
}
```

From the code above we can see:
  * The handling of each screen is common and done through the base class.
  * There is only one active screen at a time.
  * `static_ptr` only has enough size to store a single screen at a time. Different screens can freely have different sizes and alignment requirements.
  * The lifecycle of each screen is completely managed by `static_ptr`. If the current screen is valid, calling `static_ptr::make<>` will first call the destructor of the current screen, then call the constructor of the new screen.
  * `static_ptr` ensures that no screen object is accessed by means of anything else than the base class API.

Another example of this API can be seen in the `Ditto` library, in the [state machine implementation](https://github.com/Javier-varez/Ditto/blob/main/include/ditto/state_machine.h). Since only one state is valid at a time, your application only requires enough space for the largest one. But everything is allocated statically nontheless!

Many details of an actual display system implementation are omitted from the above example, but hopefully it illustrates well how the `static_ptr` type can be useful in a situation like this. I hope you found it useful and maybe you decide to use it in your next project!
