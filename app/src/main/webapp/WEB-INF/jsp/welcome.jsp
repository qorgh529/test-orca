<%@ page session="false" trimDirectiveWhitespaces="true" %>
<%@ taglib prefix="spring" uri="http://www.springframework.org/tags" %>
<%@ taglib prefix="c" uri="http://java.sun.com/jsp/jstl/core" %>
<%@ taglib prefix="petclinic" tagdir="/WEB-INF/tags" %>

<%-- Staff dashboard (docs/features/staff-dashboard/design.md). Every value is printed through c:out. --%>
<petclinic:layout pageName="home">
    <h2 id="dashboard">Staff Operations &amp; Practice Console</h2>

    <div class="row g-3 mb-4">
        <div class="col-md-4">
            <div class="card shadow-sm border-0 bg-light p-3">
                <div class="text-muted small mb-1">REGISTERED OWNERS</div>
                <div class="d-flex justify-content-between align-items-center">
                    <span class="h4 mb-0 fw-bold" id="ownerCount"><c:out value="${ownerCount}"/> Active in DB</span>
                    <a href="<spring:url value="/owners/find" htmlEscape="true"/>" class="text-decoration-none">Find &rarr;</a>
                </div>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card shadow-sm border-0 bg-light p-3">
                <div class="text-muted small mb-1">REGISTERED PATIENTS</div>
                <div class="h4 mb-0 fw-bold" id="petCount"><c:out value="${petCount}"/> Total Pets
                    <span class="fs-6 text-muted">(<c:out value="${petTypeCount}"/> Types)</span></div>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card shadow-sm border-0 bg-light p-3">
                <div class="text-muted small mb-1">RECORDED VISITS</div>
                <span class="h4 mb-0 fw-bold" id="visitCount"><c:out value="${visitCount}"/> Total Visits</span>
            </div>
        </div>
    </div>

    <div class="row g-4">
        <div class="col-lg-8">
            <div class="card shadow-sm border-0">
                <div class="card-header bg-white py-3">
                    <h5 class="mb-0 fw-bold" id="recentVisitsTitle">Recent Visits</h5>
                </div>
                <div class="card-body p-0">
                    <div class="table-responsive">
                        <table id="recentVisits" class="table table-hover align-middle mb-0" aria-describedby="recentVisitsTitle">
                            <thead class="table-light">
                            <tr>
                                <th scope="col">VISIT DATE</th>
                                <th scope="col">PET &amp; TYPE</th>
                                <th scope="col">OWNER &amp; CONTACT</th>
                                <th scope="col">DESCRIPTION / NOTES</th>
                                <th scope="col"><span class="visually-hidden">Actions</span></th>
                            </tr>
                            </thead>
                            <tbody>
                            <c:forEach items="${recentVisits}" var="visit">
                                <tr>
                                    <td class="fw-semibold"><petclinic:localDate date="${visit.date}" pattern="yyyy-MM-dd"/></td>
                                    <td><strong><c:out value="${visit.petName}"/></strong><br>
                                        <small class="text-muted"><c:out value="${visit.petType}"/>
                                            (DOB: <petclinic:localDate date="${visit.petBirthDate}" pattern="yyyy-MM-dd"/>)</small></td>
                                    <td>
                                        <spring:url value="/owners/{ownerId}" var="ownerUrl" htmlEscape="true">
                                            <spring:param name="ownerId" value="${visit.ownerId}"/>
                                        </spring:url>
                                        <a href="${ownerUrl}"><c:out value="${visit.ownerFirstName} ${visit.ownerLastName}"/></a><br>
                                        <small class="text-muted"><c:out value="${visit.ownerTelephone}"/></small></td>
                                    <td><c:out value="${visit.description}"/></td>
                                    <td>
                                        <spring:url value="/owners/{ownerId}/pets/{petId}/visits/new" var="visitUrl" htmlEscape="true">
                                            <spring:param name="ownerId" value="${visit.ownerId}"/>
                                            <spring:param name="petId" value="${visit.petId}"/>
                                        </spring:url>
                                        <a href="${visitUrl}" class="btn btn-outline-primary btn-sm">+ Add Visit</a>
                                    </td>
                                </tr>
                            </c:forEach>
                            <c:if test="${empty recentVisits}">
                                <tr><td colspan="5" class="text-muted text-center py-4">No visits recorded yet.</td></tr>
                            </c:if>
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>

        <div class="col-lg-4">
            <div class="card shadow-sm border-0 mb-4">
                <div class="card-header bg-white py-3">
                    <h5 class="mb-0 fw-bold">Find Owner</h5>
                </div>
                <div class="card-body">
                    <form action="<spring:url value="/owners" htmlEscape="true"/>" method="get" id="dashboardSearchOwnerForm">
                        <div class="input-group">
                            <input type="text" name="lastName" class="form-control" placeholder="Enter last name..."
                                   aria-label="Last name" maxlength="80">
                            <button class="btn btn-outline-secondary" type="submit">Search</button>
                        </div>
                    </form>
                </div>
            </div>

            <div class="card shadow-sm border-0">
                <div class="card-header bg-white py-3">
                    <h5 class="mb-0 fw-bold">Veterinarians Roster</h5>
                </div>
                <div class="card-body p-0">
                    <ul class="list-group list-group-flush" id="vetRoster">
                        <c:forEach items="${vets}" var="vet">
                            <li class="list-group-item">
                                <strong><c:out value="${vet.firstName} ${vet.lastName}"/></strong><br>
                                <small class="text-muted">
                                    <c:forEach var="specialty" items="${vet.specialties}" varStatus="s">
                                        <c:out value="${specialty.name}"/><c:if test="${!s.last}">, </c:if>
                                    </c:forEach>
                                    <c:if test="${vet.nrOfSpecialties == 0}">General Practice</c:if>
                                </small>
                            </li>
                        </c:forEach>
                    </ul>
                </div>
            </div>
        </div>
    </div>
</petclinic:layout>
