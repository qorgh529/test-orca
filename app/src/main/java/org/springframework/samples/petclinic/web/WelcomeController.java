/*
 * Copyright 2002-2022 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.web;

import org.springframework.samples.petclinic.service.ClinicService;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

/**
 * Staff dashboard on the home page: counts, the newest visits and the vet roster.
 */
@Controller
public class WelcomeController {

    /** Upper bound on the visits table; keeps the home page a fixed-cost query. */
    static final int RECENT_VISITS_LIMIT = 5;

    private final ClinicService clinicService;

    public WelcomeController(ClinicService clinicService) {
        this.clinicService = clinicService;
    }

    @GetMapping({"/", "/welcome"})
    public String showDashboard(Model model) {
        model.addAttribute("ownerCount", this.clinicService.countOwners());
        model.addAttribute("petCount", this.clinicService.countPets());
        model.addAttribute("petTypeCount", this.clinicService.findPetTypes().size());
        model.addAttribute("visitCount", this.clinicService.countVisits());
        model.addAttribute("recentVisits", this.clinicService.findRecentVisits(RECENT_VISITS_LIMIT));
        model.addAttribute("vets", this.clinicService.findVets());
        return "welcome";
    }

}
