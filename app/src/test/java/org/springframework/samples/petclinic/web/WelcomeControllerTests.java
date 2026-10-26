package org.springframework.samples.petclinic.web;

import java.util.List;

import org.assertj.core.util.Lists;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.samples.petclinic.model.PetType;
import org.springframework.samples.petclinic.model.Vet;
import org.springframework.samples.petclinic.model.Visit;
import org.springframework.samples.petclinic.service.ClinicService;
import org.springframework.test.context.junit.jupiter.web.SpringJUnitWebConfig;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.servlet.view.InternalResourceViewResolver;

import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringJUnitWebConfig(locations = {"classpath:spring/mvc-core-config.xml", "classpath:spring/mvc-test-config.xml"})
class WelcomeControllerTests {

    @Autowired
    private WelcomeController welcomeController;

    @Autowired
    private ClinicService clinicService;

    private MockMvc mockMvc;

    @BeforeEach
    void setup() {
        // Same prefix as mvc-view-config.xml, so view "welcome" on /welcome is not taken for a loop.
        this.mockMvc = MockMvcBuilders.standaloneSetup(welcomeController)
            .setViewResolvers(new InternalResourceViewResolver("/WEB-INF/jsp/", ".jsp"))
            .build();
        given(this.clinicService.countOwners()).willReturn(10L);
        given(this.clinicService.countPets()).willReturn(13L);
        given(this.clinicService.countVisits()).willReturn(4L);
        given(this.clinicService.findPetTypes()).willReturn(Lists.newArrayList(new PetType(), new PetType()));
        given(this.clinicService.findRecentVisits(WelcomeController.RECENT_VISITS_LIMIT))
            .willReturn(List.of(new Visit()));
        given(this.clinicService.findVets()).willReturn(Lists.newArrayList(new Vet()));
    }

    @Test
    void testShowDashboard() throws Exception {
        mockMvc.perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(view().name("welcome"))
            .andExpect(model().attribute("ownerCount", 10L))
            .andExpect(model().attribute("petCount", 13L))
            .andExpect(model().attribute("petTypeCount", 2))
            .andExpect(model().attribute("visitCount", 4L))
            .andExpect(model().attributeExists("recentVisits", "vets"));
    }

    @Test
    void testWelcomeAliasAndBoundedRecentVisits() throws Exception {
        mockMvc.perform(get("/welcome"))
            .andExpect(status().isOk())
            .andExpect(view().name("welcome"));
        verify(this.clinicService, atLeastOnce()).findRecentVisits(WelcomeController.RECENT_VISITS_LIMIT);
    }

}
